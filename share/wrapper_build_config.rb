# mruby-lsp wrapper build config.
#
# Builds a SEPARATE, renamed parallel target (<base>-mruby-lsp) so the user's
# own build/<their-target>/ tree is never touched. We load their build_config.rb
# verbatim, but intercept MRuby::Build.new: when their config defines the primary
# build, we instead define a parallel build named "<base>-mruby-lsp", replay
# their exact settings into it, and add ONLY what reflection needs:
#   - reflection floor:
#       mruby-metaprog + mruby-method  (core: ancestors/instance_methods/
#                                       singleton_class/constants + instance_method/
#                                       parameters/source_location)
#       + mruby-str-constantize (declared via github: Asmod4n/...), which pulls
#         its dep mruby-c-ext-helpers. The reflect ext does a VM-level
#         `name.constantize` (name string -> class constant) -- without
#         str-constantize in the build, the ext's funcall raises at runtime, so
#         this is part of the floor, not optional. Declared like any gem --
#         mruby fetches it, NOT vendored.
#   - conf.enable_debug              (C -g3 -O0 for addr2line AND mrbc -g -> irep
#                                     debug_info -> Ruby source_location; NOT -g)
#   - -fPIC on cc AND cxx AND linker (libmruby.a links into the host MRI .so;
#                                     archive holds C++ objs too -- str-constantize
#                                     is C++ -- so cxx needs PIC)
# Their build_config.rb is never edited.
#
# Renamed (not reopened) because mruby derives build_dir from the build name, so
# build/<base>-mruby-lsp/ holds everything of ours and nothing of theirs.
#
# Intercept construction (not static parse) because a build_config.rb is
# arbitrary Ruby; only *running* it yields the real build name and resolved gem
# set. Hooking Build.new hands us the already-evaluated name and a live conf.
#
# What this NO LONGER does (vs reference/wrapper_build_config.OLD.rb): inject an
# LSP-server gem, shadow mrb_define* via the preprocessor, or emit
# compile_commands.json. addr2line replaced the locator; the parallel libmruby
# is now side-effect-free -- a -fPIC + enable_debug + reflection-floor build for
# the host ext to reflect, nothing else.
#
# Env:
#   MRUBY_LSP_USER_CONFIG  absolute path to the user's build_config.rb
#   MRUBY_LSP_BASE_BUILD   user build to mirror (default 'host')

user_config = ENV.fetch('MRUBY_LSP_USER_CONFIG')
base_name   = ENV['MRUBY_LSP_BASE_BUILD'] # nil = intercept the primary build

# No lockfile for this build process. mruby's Lockfile.write always emits the
# file when globally enabled (>= the `mruby:` block), and a recorded lock entry
# pins github: gems to a resolved commit (build/load_gems.rb reuses the locked
# ref instead of the branch) -- which would freeze users on a stale floor gem
# and defeat `branch: 'main'`. The file is also written next to MRUBY_CONFIG --
# i.e. INTO this gem's share/ -- so it leaks into the shipped gem/tree. Disable
# globally so write() is a full no-op: no pin, no file. This is scoped to the
# wrapper-driven build process; the user's own `rake` (separate process, own
# config) keeps its build_config.rb.lock, which build_discovery relies on.
# Refresh path stays `mruby-lsp-update gems` (clears the fetch/ dir -> re-clone).
MRuby::Lockfile.disable

# Intercept construction of the primary build only.
#
# Prepend to MRuby::Build's singleton class so our `new` sits in front of
# mruby's own Build.new. MRuby::CrossBuild is a subclass of Build, so
# CrossBuild.new dispatches here too; the `self == MRuby::Build` guard leaves
# cross targets -- and mruby's internal builds (internal: true) -- untouched, so
# only the user's primary host build gets mirrored.
module MRubyLSPInject
  class << self
    attr_accessor :base_name, :intercepted
  end

  def new(name = 'host', *args, **kwargs, &block)
    inj = MRubyLSPInject
    # Intercept the user's PRIMARY build: the first non-internal MRuby::Build
    # the config defines, regardless of its name (configs name builds anything —
    # 'host' is only the default). An explicit MRUBY_LSP_BASE_BUILD still pins a
    # specific name for multi-build configs. mruby 4 lockfiles carry no build
    # names, so name-matching against the lock is no longer possible anyway.
    wanted = inj.base_name ? name.to_s == inj.base_name : !inj.intercepted
    if self == MRuby::Build && !kwargs[:internal] && wanted
      inj.intercepted = true
      MRubyLSPInject.define_variant(self, "#{name}-mruby-lsp", args, kwargs, &block)
    else
      super
    end
  end

  # Define the renamed parallel build. We pass an already-renamed (non-matching)
  # target name, so the plain klass.new below flows through our `new`, hits the
  # else branch (name != base_name), and calls super -- the real Build.new, with
  # its full flow (incl. create_mrbc_build in the ensure block).
  def self.define_variant(klass, target, args, kwargs, &block)
    klass.new(target, *args, **kwargs) do |conf|
      # Air-gap (FS separation): keep fetched gem CLONES out of the build tree.
      # mruby defaults gem_clone_dir to <build_dir>/repos, i.e. inside what we
      # build; redirect it to a disjoint sibling fetch/ dir so the fetch and
      # build phases never write each other's trees. Must run BEFORE the user's
      # config replay below, since their `conf.gem github:/git:` calls clone
      # immediately using whatever gem_clone_dir is set at that moment.
      fetch_root = ENV["MRUBY_LSP_FETCH_DIR"]
      if fetch_root && !fetch_root.empty?
        conf.gem_clone_dir = File.join(fetch_root, "repos", conf.name.to_s)
      end

      # Replay the user's exact settings. instance_eval so both bare receiver
      # calls (toolchain :gcc / gem ... / enable_debug) and explicit conf.* calls
      # resolve on this build (instance_eval yields self to the block param too).
      conf.instance_eval(&block) if block

      # Reflection floor (core): the ext needs metaprog (ancestors/
      # instance_methods/singleton_class/constants) and method (instance_method/
      # parameters/source_location). Add only if the replayed config didn't.
      conf.gem core: 'mruby-metaprog' unless conf.gems.any? { |g| g.name == 'mruby-metaprog' }
      conf.gem core: 'mruby-method'   unless conf.gems.any? { |g| g.name == 'mruby-method' }

      # Reflection floor (external): str-constantize provides the VM-level
      # `name.constantize` the ext calls. Declared like any other mruby gem —
      # mruby's own machinery fetches it (and pulls mruby-c-ext-helpers as ITS
      # declared dependency). NOT vendored. Skip if the user's config already
      # has it (by name).
      unless conf.gems.any? { |g| g.name == 'mruby-str-constantize' }
        conf.gem github: 'Asmod4n/mruby-str-constantize', branch: 'main'
      end

      # Reflection floor (external): mruby-irep-reflect exposes a method's
      # irep-derived return type (Stage 2 type inference) using only public mruby
      # headers. Declared like any gem; the build system pulls it. Stand-alone
      # work, so its own gem (later github; dev: in-tree gems/). If absent, the
      # reflect ext's return_type op degrades to nil (Stage 2 simply off).
      unless conf.gems.any? { |g| g.name == 'mruby-irep-reflect' }
        conf.gem gemdir: File.expand_path('../gems/mruby-irep-reflect', __dir__)
      end

      # Reflection floor (external): mruby-lsp-ccj emits a clangd-shape
      # compile_commands.json into the injected build's build_dir (source-less
      # gem; one build task depending on libmruby_static, so it reruns on every
      # relink and rebuilds the whole DB -- no partial-build truncation). clangd
      # (Stage 3) reads it via --compile-commands-dir; CLocator reads it for C
      # source flags. Adds NO C code. Absent -> no DB -> Stage 3/C features off.
      unless conf.gems.any? { |g| g.name == 'mruby-lsp-ccj' }
        conf.gem gemdir: File.expand_path('../gems/mruby-lsp-ccj', __dir__)
      end

      # value_bridge: the neutral mrb_value <-> vb_value marshaller the reflect
      # ext uses instead of a bespoke byte protocol. Compiles its core + mruby
      # leg into libmruby and exports vb.h/vb_mruby.h; pulls mruby-proc-irep-ext
      # (PROC tag) as its declared dependency. The ext's CRuby leg builds in
      # ext/mruby_reflect/extconf.rb. NOTE: changing the gem set requires
      # `rake deep_clean` before rebuilding -- stale objects corrupt VM init.
      unless conf.gems.any? { |g| g.name == 'mruby-value-bridge' }
        # Vendored internal gem: the mgem face (mrbgem.rake + mruby leg + core)
        # lives in this gem's vendor/value_bridge and ships inside it, so the
        # mruby build always finds it -- no fetch, no sibling, no install needed
        # for the build side. (share/ -> ../vendor/value_bridge)
        conf.gem gemdir: File.expand_path('../vendor/value_bridge', __dir__)
      end

      # mruby-platform: bakes the build's OS + toolchain into the VM as frozen
      # constants (Platform::OS / Platform::Toolchain) via compile-time #ifdefs,
      # so the reflect side learns from VM truth which symbolizer to expect
      # instead of guessing the environment. Vendored; compiles into libmruby.
      # value_bridge declares a name-only add_dependency on it purely for init
      # ORDER; THIS line is what actually puts it in the build. Absent -> the
      # constants are simply not there and the consumer degrades.
      unless conf.gems.any? { |g| g.name == 'mruby-platform' }
        conf.gem gemdir: File.expand_path('../vendor/mruby-platform', __dir__)
      end

      # mruby-native-ext-type: a class can declare its ivar types
      # (`native_ext_type :@x, Type`); the gem stores them and exposes
      # `Klass.net_schema`, which the reflect ext reads for ivar typing. ALWAYS
      # injected so `net_schema` exists in the reflected VM regardless of the
      # user's config — the bridge op can then always query it (undeclared
      # classes return nil) instead of the method being absent. Declared via
      # github like mruby-str-constantize (Lockfile.disable above keeps users on
      # branch HEAD). Skip if the user already declares it.
      unless conf.gems.any? { |g| g.name == 'mruby-native-ext-type' }
        conf.gem github: 'Asmod4n/mruby-native-ext-type', branch: 'main'
      end

      # Debug info for BOTH locators: C addr2line and Ruby source_location.
      conf.enable_debug

      # PIC for linking libmruby.a into the host MRI .so (x86-64 shared object).
      # cxx included because the archive may contain C++ objects.
      conf.cc.flags     << '-fPIC'
      conf.cxx.flags    << '-fPIC'
      conf.linker.flags << '-fPIC'
    end
  end
end

MRubyLSPInject.base_name = base_name
MRuby::Build.singleton_class.prepend(MRubyLSPInject)

# Load their config verbatim, evaluated at its own path so __FILE__/__dir__
# inside it still resolve. Every MRuby::Build.new it runs flows through the hook;
# the matching primary build becomes <name>-mruby-lsp, everything else (cross
# targets, extra builds) is created exactly as written.
eval(File.read(user_config), TOPLEVEL_BINDING, user_config)
