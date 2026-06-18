# frozen_string_literal: true

# mruby-lsp setup <project-path> — the implementation behind the `mruby-lsp-setup`
# command. The launcher (or, off Linux, the install hook's pass-through) confines
# and then runs `MrubyLsp::CLI.run("setup", [project])`, which lands here.
#
# The ONE setup command. Takes the user's project path and does everything:
#
#   1. discover   — find the project's mruby root + build config (lock-anchored,
#                   same BuildDiscovery the server uses)
#   2. build      — rake libmruby through our wrapper config (replays the user's
#                   config, declares the reflection floor gems (mruby fetches them), enable_debug, -fPIC),
#                   into the cache — the user's tree is never touched
#   3. compile    — build the mruby_reflect .so against that libmruby
#   4. record     — write paths.env so the server + editor extension find it all
#
# Idempotent: re-running rebuilds only what changed (rake's own dependency
# tracking). All artifacts live under <passwd-home>/.cache/mruby-lsp/<project-key>/
# — a FIXED path from the passwd DB (BuildDiscovery.cache_dir), never $XDG/$HOME.

require "fileutils"
require "time"
require "rbconfig"

require_relative "build_discovery"

module MrubyLsp
  module Setup
    module_function

    # The installed gem root: lib/mruby_lsp/setup.rb -> ../.. == the gem dir.
    GEM_ROOT = File.expand_path(File.join(__dir__, "..", ".."))

    def step(name)
      puts "==> #{name}"
      yield
    end

    def fail!(msg)
      warn "mruby-lsp-setup: #{msg}"
      exit 1
    end

    # Locate the mruby-lsp-nonet wrapper (the seccomp AF_INET/AF_INET6 deny used to
    # run the OFFLINE build phase). It's compiled by extconf into the same bindir as
    # the launcher, so the realpath sibling is the primary lookup; fall back to the
    # recorded install bin and finally PATH. Returns nil when it isn't on disk
    # (non-Linux, or its optional build failed) — the caller then runs the build
    # unwrapped (the fetch/build FS split still stands). NOT env-steered: no var
    # picks the path or toggles the seal; we only consult fixed locations. (Under
    # the launcher we run as `ruby -e …`, so $PROGRAM_NAME is "-e" and the realpath
    # sibling probe simply no-ops; the recorded install.json bin resolves it.)
    def locate_nonet
      ext = RbConfig::CONFIG["EXEEXT"]
      name = "mruby-lsp-nonet#{ext}"
      candidates = []
      begin
        candidates << File.join(File.dirname(File.realpath($PROGRAM_NAME)), name)
      rescue SystemCallError
        # $0 not a real path (e.g. `ruby -e`); skip the sibling probe
      end
      # FIXED path: the install hook wrote install.json under the passwd-DB home
      # (env-free), so read it from the same place — never $XDG_DATA_HOME/$HOME.
      install = File.join(
        MrubyLsp::Discovery::BuildDiscovery.home_dir, ".local", "share",
        "mruby-lsp", "install.json"
      )
      if File.file?(install)
        require "json"
        begin
          bin = JSON.parse(File.read(install))["bin"]
          candidates << File.join(bin, name) if bin
        rescue JSON::ParserError
          # malformed install.json -> ignore, fall through to PATH
        end
      end
      (ENV["PATH"] || "").split(File::PATH_SEPARATOR).each do |dir|
        candidates << File.join(dir, name) unless dir.empty?
      end
      candidates.find { |p| File.file?(p) && File.executable?(p) }
    end

    # GEM_PATH for the compile children (the mruby `rake` build and the reflect
    # extconf). The editor extension launches us with GEM_PATH pointed at its
    # bundled gems so our own requires resolve; but when the editor itself ran with
    # GEM_PATH UNSET, the extension's "prepend bundle onto prior" hit an empty prior
    # and produced a bundle-ONLY path, which overrides Ruby's built-in default gem
    # dirs -> `rake` is invisible ("can't find gem rake"). Gem.default_path is the
    # compiled-in default set, independent of the clobbered ENV; union it with the
    # current (bundled) path so BOTH our bundled gems (value_bridge for extconf) and
    # system gems (rake) resolve. Prepend, never replace.
    BUILD_GEM_PATH = (
      (ENV["GEM_PATH"] || "").split(File::PATH_SEPARATOR) +
      Gem.default_path + [Gem.user_dir, Gem.dir]
    ).reject { |p| p.nil? || p.empty? }.uniq.join(File::PATH_SEPARATOR)

    def run(argv)
      # ── -1. restore recorded mtimes ───────────────────────────────────────────
      # `gem install` stamps extraction-time mtimes on every file. mruby's build and
      # make are mtime-driven, so a reinstall of byte-identical files rebuilt
      # EVERYTHING (libmruby + reflect .so) and churned the v-<stamp> dir. The gem
      # ships share/mtimes.json recorded at `rake gem:build`; restoring those stamps
      # makes unchanged content a no-op. Per-file rescue: system gem dirs may be
      # read-only -- then the rebuild simply happens, same as before this fix.
      mtimes_manifest = File.join(GEM_ROOT, "share", "mtimes.json")
      if File.exist?(mtimes_manifest)
        require "json"
        restored = 0
        JSON.parse(File.read(mtimes_manifest)).each do |rel, epoch|
          path = File.join(GEM_ROOT, rel)
          next unless File.file?(path)
          t = Time.at(epoch)
          next if File.mtime(path) == t
          begin
            File.utime(t, t, path)
            restored += 1
          rescue SystemCallError
            # read-only gem dir: leave it; worst case is the old rebuild behavior
          end
        end
        warn "mruby-lsp-setup: restored #{restored} recorded mtimes" if restored > 0
      end

      # ── 0. argument ───────────────────────────────────────────────────────────

      project = argv[0] or fail!("usage: mruby-lsp-setup <project-path>")
      project = File.expand_path(project)
      fail!("no such directory: #{project}") unless Dir.exist?(project)

      # ── cache layout ──────────────────────────────────────────────────────────

      # Cache root is BuildDiscovery's single source of truth (passwd-home based, NOT
      # $XDG/$HOME — see BuildDiscovery.home_dir), so setup, server and update agree
      # and the launcher's Landlock allow-list always contains it.
      cache = MrubyLsp::Discovery::BuildDiscovery.cache_dir(project)
      FileUtils.mkdir_p(cache)

      # ── 1. discover ───────────────────────────────────────────────────────────

      mruby_root = nil
      user_config = nil
      step("discovering mruby in #{project}") do
        mruby_root = MrubyLsp::Discovery::BuildDiscovery.resolve_mruby_root(project)
        fail!("no mruby checkout found under #{project} (expected e.g. #{project}/mruby)") unless mruby_root

        result = MrubyLsp::Discovery::BuildDiscovery.discover(project)
        case result.status
        when :resolved
          user_config = result.config_path
        when :ambiguous
          puts "    multiple built configs found:"
          result.candidates.each_with_index do |c, i|
            puts "      [#{i + 1}] #{c.config_path}"
          end
          print "    choose [1-#{result.candidates.size}]: "
          choice = $stdin.gets.to_i
          fail!("invalid choice") unless choice.between?(1, result.candidates.size)
          user_config = result.candidates[choice - 1].config_path
          MrubyLsp::Discovery::BuildDiscovery.save_choice(project, user_config, mruby_root: mruby_root)
        when :none
          fail!("no built config found (no *.rb.lock). Build your project once (rake) so mruby-lsp can see which config you use.")
        end

        puts "    mruby root:  #{mruby_root}"
        puts "    user config: #{user_config}"
      end

      # ── 2. build libmruby through the wrapper (never touching the user's tree) ──

      build_dir = File.join(cache, "build")
      # Air-gap (FS separation): fetched gem clones go in a DISJOINT sibling, never
      # inside build_dir. The wrapper points mruby's gem_clone_dir here.
      fetch_dir = File.join(cache, "fetch")
      wrapper = File.join(GEM_ROOT, "share", "wrapper_build_config.rb")
      fail!("wrapper config missing from gem at #{wrapper}") unless File.exist?(wrapper)

      # Native-code fingerprint: the cached build (libmruby + reflect_so) is compiled
      # from the gem's C sources. mruby's build is mtime-driven and we restore mtimes
      # to keep reinstalls quiet, so a CONTENT change to native code (e.g. an updated
      # value_bridge or reflect .c shipped by a new extension version) would NOT be
      # noticed -- the stale objects persist and the server runs new Ruby against an
      # ABI-mismatched reflect_so. To catch exactly that, hash every native input that
      # feeds the build (shared with the packaging task, so the extension can compare);
      # if it differs from what the cache was last built against, wipe the build +
      # reflect_so so they recompile from clean. A Ruby-only update leaves the hash
      # unchanged -> the cache is reused. Content-based, immune to versions and mtimes.
      require_relative "native_fingerprint"
      native_digest = MrubyLsp::NativeFingerprint.digest(GEM_ROOT)

      native_marker = File.join(cache, "native.sha256")
      prior_digest = (File.read(native_marker).strip if File.exist?(native_marker))
      if prior_digest && prior_digest != native_digest
        warn "mruby-lsp-setup: native code changed since last build — forcing a clean rebuild"
        FileUtils.rm_rf(build_dir)
        FileUtils.rm_rf(File.join(cache, "mruby_reflect"))
      end

      step("building libmruby (debug + PIC, into cache) — this can take a few minutes") do
        env = {
          "MRUBY_CONFIG"          => wrapper,
          "MRUBY_BUILD_DIR"       => build_dir,          # mruby-native: relocates ALL build artifacts into our cache
          "MRUBY_LSP_FETCH_DIR"   => fetch_dir,          # air-gap: gem clones land here, not under build_dir
          "MRUBY_LSP_USER_CONFIG" => user_config,
          "GEM_PATH"              => BUILD_GEM_PATH,      # keep system `rake` visible (see BUILD_GEM_PATH note)
        }

        # Air-gap PHASE 1 — FETCH (network ALLOWED). Cloning github:/git: gems is a
        # side-effect of evaluating the wrapper config (gem_clone_dir -> fetch/), and
        # `rake fetch` runs that eval without building, so this pulls every declared
        # gem and its deps into fetch/ over the network. Idempotent: already-present
        # repos are skipped.
        ok = system(env, "rake", "fetch", chdir: mruby_root)
        fail!("gem fetch failed (see output above)") unless ok

        # Air-gap PHASE 2 — BUILD (network DENIED). Run the real build behind the
        # mruby-lsp-nonet seccomp wrapper so a hostile mrbgem.rake / gcc plugin / build
        # script in the fetched code can't open an AF_INET/AF_INET6 socket — it can't
        # phone home or pull more code. Local IPC (Unix sockets, pipes) and file I/O
        # are untouched, so the build itself is unaffected. Config re-eval re-runs the
        # clone calls, but they're idempotent (repos present) so no network is needed.
        # Degrade-safe: if the wrapper isn't on disk (non-Linux, or its optional build
        # failed) we build unwrapped — the fetch/build FS split still holds.
        nonet = locate_nonet
        if nonet
          build_cmd = [nonet, "rake"]
        else
          warn "    mruby-lsp-nonet not found — building without the network seal " \
               "(fetch/build FS split still applies)"
          build_cmd = ["rake"]
        end
        ok = system(env, *build_cmd, chdir: mruby_root)
        fail!("mruby build failed (see output above)") unless ok
      end

      # Locate the produced libmruby + build name (the wrapper names it <base>-mruby-lsp).
      libmruby = Dir.glob(File.join(build_dir, "*-mruby-lsp", "lib", "libmruby.a")).first ||
                 Dir.glob(File.join(build_dir, "*", "lib", "libmruby.a")).first
      fail!("libmruby.a not found under #{build_dir}") unless libmruby
      mruby_build = File.dirname(File.dirname(libmruby))

      # ── 3. compile the reflect .so ────────────────────────────────────────────

      ext_dir = File.join(cache, "mruby_reflect")
      step("compiling mruby_reflect.so") do
        FileUtils.mkdir_p(ext_dir)
        %w[mruby_tu.c bridge_tu.c bridge.h extconf.rb].each do |f|
          src = File.join(GEM_ROOT, "ext", "mruby_reflect", f)
          fail!("gem is missing ext/mruby_reflect/#{f}") unless File.exist?(src)
          dst = File.join(ext_dir, f)
          # Idempotent: only touch dst when the CONTENT differs. If we copied
          # unconditionally, every setup run would stamp a fresh mtime and mruby's
          # mtime-driven build would recompile the ext even for byte-identical source.
          # When we do copy, preserve the source mtime.
          next if File.exist?(dst) && File.binread(dst) == File.binread(src)

          FileUtils.cp(src, dst, preserve: true)
        end

        # Skip extconf+make entirely when the existing .so is already consistent:
        # newer than every ext source AND than libmruby.a. Running them anyway is
        # never a no-op -- extconf rewrites the Makefile and mkrf/mkmf RELINKS,
        # restamping the .so and churning the v-<stamp> dir (and with it paths.env)
        # on every single setup run.
        so = File.join(ext_dir, "mruby_reflect.so")
        inputs = Dir.glob(File.join(ext_dir, "*.{c,h,rb}")) + [libmruby]
        if File.exist?(so) && inputs.all? { |f| File.mtime(f) <= File.mtime(so) }
          puts "    up to date, skipping"
        else
          env = {
            "MRUBY_DIR"          => mruby_root,
            "MRUBY_BUILD"        => mruby_build,
            "GEM_PATH"           => BUILD_GEM_PATH,     # keep our bundled value_bridge AND system gems visible
          }
          ok = system(env, RbConfig.ruby, "extconf.rb", chdir: ext_dir) &&
               system("make", chdir: ext_dir)
          fail!("reflect extension build failed") unless ok
        end
      end

      reflect_so = File.join(ext_dir, "mruby_reflect.so")
      fail!("mruby_reflect.so missing after build") unless File.exist?(reflect_so)

      # Version by DIRECTORY (not filename): CRuby's require of a C extension calls
      # Init_<basename>, so the file must stay mruby_reflect.so — but require caches
      # by full path, so a rebuilt VM needs a NEW path for a long-lived server to
      # load it fresh. v-<build-stamp>/mruby_reflect.so satisfies both.
      # NO HASHING (project rule): keys must be derivable identically by every
      # implementation and eyeballable when they disagree. The .so's mtime is a
      # plain, inspectable stamp; consumers never derive it — they read paths.env.
      so_stamp = File.mtime(reflect_so).strftime("%Y%m%d%H%M%S")
      versioned_dir = File.join(ext_dir, "v-#{so_stamp}")
      FileUtils.mkdir_p(versioned_dir)
      versioned_so = File.join(versioned_dir, "mruby_reflect.so")
      FileUtils.cp(reflect_so, versioned_so) unless File.exist?(versioned_so)
      # prune older version dirs (keep current)
      Dir.glob(File.join(ext_dir, "v-*")).each do |old|
        FileUtils.rm_rf(old) unless old == versioned_dir
      end
      reflect_so = versioned_so

      # ── 4. record the handoff ──────────────────────────────────────────────────

      step("recording paths.env") do
        # Record which version produced this cache, so the editor extension can detect
        # when it (or the gem) has been updated since the last build and offer/perform
        # a rebuild. Prefer an explicit MRUBY_LSP_VERSION (the extension passes its own
        # version), else the gem's VERSION file.
        built_with =
          ENV["MRUBY_LSP_VERSION"] ||
          (File.exist?(File.join(GEM_ROOT, "VERSION")) ? File.read(File.join(GEM_ROOT, "VERSION")).strip : nil) ||
          "unknown"

        File.write(File.join(cache, "paths.env"), <<~ENVFILE)
          reflect_so=#{reflect_so}
          libmruby=#{libmruby}
          mruby_root=#{mruby_root}
          mruby_build=#{mruby_build}
          build_dir=#{build_dir}
          cache_dir=#{cache}
          project=#{project}
          built_with=#{built_with}
        ENVFILE

        # Stamp the native-code fingerprint this build was made against. Next setup
        # compares it (above) and forces a clean rebuild iff the C sources changed.
        # Written only here, after a successful build+compile, so a failed run never
        # leaves a stamp claiming the (broken/partial) cache is current.
        File.write(File.join(cache, "native.sha256"), native_digest)
      end

      # Record build-completion state in the user's OWN state store (~/.local/share,
      # keyed by workspace path) — NEVER in the user's project. A hostile/cloned repo
      # must not be able to forge "this project is set up" or point us anywhere. This
      # is the only state we persist about the project, and it lives outside it.
      step("recording setup state") do
        require "json"
        dir = MrubyLsp::Discovery::BuildDiscovery.state_dir(project)
        FileUtils.mkdir_p(dir)
        cfg_path = File.join(dir, "config.json")
        cfg =
          if File.file?(cfg_path)
            begin
              JSON.parse(File.read(cfg_path))
            rescue JSON::ParserError
              {} # malformed config.json -> start fresh
            end
          else
            {}
          end
        cfg["config"]     = user_config
        cfg["mruby_root"] = mruby_root
        cfg["project"]    = project
        cfg["native"]     = native_digest  # the native fingerprint this workspace was built against
        # No setup.done flag: "set up" is whether the build's final artifact (the
        # reflect_so named in paths.env) actually exists. A flag written only at the end
        # lies when a forced rebuild deletes the old build and then fails — the editor
        # checks the artifact instead, which can't go stale.
        File.write(cfg_path, JSON.pretty_generate(cfg) + "\n")
      end

      puts
      puts "Done. mruby-lsp is set up for #{project}"
      puts "  reflect_so: #{reflect_so}"
      puts "Open the project in your editor — the mruby-lsp extension/shim picks it up."
    end
  end
end
