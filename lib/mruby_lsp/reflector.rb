# frozen_string_literal: true

require "set"
require "value_bridge"
require_relative "doc_extractor"
require_relative "c_locator"
require_relative "param_format"

module MrubyLsp
  # T3.2 — the load-bearing piece. The live mruby VM IS the source of truth.
  #
  # Reflector opens the project's reflect_so (an MRI C-extension that links the
  # project's compiled libmruby and exposes its class/method graph) and walks it
  # into plain Index::Entry records. NO CRuby, NO RBS, NO static parsing — only
  # what the built VM actually contains.
  #
  # The reflect_so path comes from MRUBY_REFLECT_SO (set by the build/setup step,
  # same contract as before). The C-ext API (proven, reused unchanged):
  #   constants(namespace)        -> Array<String>  constant names under namespace
  #   instance_methods(klass)     -> Array<String>  method names on klass
  #   parameters(klass, method)   -> flat [kind,name, kind,name, ...]
  #   source_location(klass, m)   -> [path_or_nil, line_or_nil] for Ruby methods
  #   cfunc_offset(klass, method) -> Integer offset for C methods (nil if Ruby)
  #   ancestors(klass)            -> Array<String>  linearized ancestor names
  class Reflector
    SYNTHETIC_SCHEME = "mruby-core"

    # Open the reflect_so and return a Reflector, or nil if unavailable.
    def self.open(so_path = ENV["MRUBY_REFLECT_SO"], mruby_root: nil)
      return nil unless so_path && File.exist?(so_path)

      require so_path
      new(Object.const_get(:MrubyReflect).new, so_path: so_path, mruby_root: mruby_root)
    rescue LoadError, NameError
      nil
    end

    # Canonical alias/proc-backed C methods. On an mruby built BEFORE
    # mruby/mruby#6879, Method#source_location on an aliased C method
    # dereferences the alias proc's body.mid as an irep -> SIGSEGV/SIGABRT.
    ALIAS_PROBE = [["Proc", "[]"], ["Proc", "call"], ["Class", "new"],
                   ["BasicObject", "!="]].freeze

    # Crash-safe guard for the alias-source_location segfault (mruby#6879).
    # That crash is C-level: mrb_protect_error and Ruby `rescue` CANNOT catch
    # it, so it would take the whole server down mid-populate. We test the exact
    # operation in a FORKED CHILD first; if the child dies by signal, this mruby
    # build is unsafe to reflect and the caller must skip the walk. Returns true
    # when reflection is safe (or when we can't isolate, e.g. no fork).
    def self.alias_safe?(so_path = ENV["MRUBY_REFLECT_SO"])
      return true unless so_path && File.exist?(so_path)
      # No fork (e.g. Windows MRI): we cannot isolate, so assume safe. This is a
      # capability precondition, NOT a rescue — fork's absence is knowable up
      # front, and neither a fork failure nor a C-level segfault is catchable by
      # a Ruby `rescue` anyway (the whole point of isolating in a child).
      return true unless Process.respond_to?(:fork)

      pid = fork do
        $stderr.reopen(File::NULL, "w")
        # A Ruby-level error here exits the child non-zero but NOT by signal,
        # which the parent reads as safe; only a C-level signal death (segfault
        # on an unfixed build) flips alias_safe? to false. The signal-vs-exit
        # distinction is the whole test, so no rescue is needed.
        require so_path
        r = Object.const_get(:MrubyReflect).new
        ALIAS_PROBE.each do |cls, meth|
          ims = r.instance_methods(cls)
          next unless ims.is_a?(Array) && ims.map(&:to_s).include?(meth)
          r.source_location(cls, meth) # <- segfaults on an unfixed build
        end
        exit!(0)
      end
      _pid, status = Process.wait2(pid)
      !status.signaled?
    end

    def initialize(reflect, so_path: nil, mruby_root: nil)
      @reflect = reflect
      @mruby_root = mruby_root
      @doc = DocExtractor.new
      # The CLocator must address THE .so this reflector opened — the path is
      # right here, so hand it over. The env-var default only ever existed for
      # ad-hoc runs and silently produced location-less C entries the moment a
      # real launch (no env) used setup-built artifacts.
      # Compile-time facts mruby-platform baked into THIS VM -- { os:, toolchain: }
      # symbols. The gem is a build INVARIANT (like enable_debug): no Platform in
      # the VM means the build is broken, so raise -- don't quietly carry on with
      # a guessed backend. (No respond_to? guard either: a stale .so without
      # #platform should surface as NoMethodError, i.e. "rebuild".)
      pf = @reflect.platform
      unless pf.is_a?(Array) && pf.size == 2
        raise "mruby-lsp: Platform constants missing from the VM -- the " \
              "mruby-platform gem is not in this build. Rebuild with " \
              "`mruby-lsp-update rebuild`."
      end
      @platform = { os: pf[0], toolchain: pf[1] }
      @clocator = CLocator.open(so_path || ENV["MRUBY_REFLECT_SO"], platform: @platform)
      # The in-libmruby anchor address (&mrb_open), read ONCE. Ruby subtracts
      # this from each method's raw C-function address to form the ASLR-invariant
      # offset that keys the nm sidecar. All offset math lives here, not in C.
      @anchor_addr = @reflect.anchor_addr
    end

    # VM-baked platform facts: { os:, toolchain: } symbols, or nil if the
    # mruby-platform gem isn't in this build.
    def platform
      @platform
    end

    # Walk the whole VM into the index. Idempotent per Reflector instance.
    # MRUBY_LSP_TIMING=1 prints phase timings to stderr -- field diagnosis for
    # slow startups without shipping a different build.
    def populate(index)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      phase = lambda do |name|
        next unless ENV["MRUBY_LSP_TIMING"]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        warn format("mruby-lsp timing: %-18s %6.0fms", name, (now - t0) * 1000)
        t0 = now
      end
      index.native_resolver = NativeResolver.new(@clocator)
      index.mruby_root = @mruby_root
      namespaces = enumerate_namespaces
      phase.call("enumerate")
      namespaces.each do |ns|
        record_ancestors(index, ns) # first: entry typing reads the recorded MRO
        # No MRO == not a module/class: ancestors() raises on a value (Float::
        # INFINITY, CBOR::TAG_*). Those are VALUE CONSTANTS — record them as
        # :constant (previously they fell through vm_class?==nil to :class,
        # mislabeled AND method-enumerated pointlessly).
        if index.vm_class?(ns).nil? && ns.include?("::")
          add_value_constant_entry(index, ns)
          next
        end
        add_class_entry(index, ns)
        record_ivar_schema(index, ns)
        add_method_entries(index, ns)
        add_private_method_entries(index, ns)
        add_singleton_method_entries(index, ns)
      end
      phase.call("entries+ruby_docs")
      index.special_methods = builtin_special_methods
      # Locations EAGERLY via ONE batched addr2line (~50ms for the whole VM):
      # completion shows the C source file again, hover/definition need no
      # location work. Only the RDoc doc extraction stays lazy (Index#enrich).
      if @clocator
        index.apply_native_locations(@clocator) # primes + rewrites all tables
        phase.call("native locations")
      end
      index
    end

    # Private instance methods (Kernel#puts/p/print, a class's own privates).
    # Stored SEPARATELY on the index (not in the public method table) so explicit-
    # receiver completion stays public-only, while BARE/implicit-self completion
    # can offer them — they are callable without a receiver.
    def add_private_method_entries(index, klass)
      methods = reflect_names(@reflect.private_instance_methods(klass, false),
                              "private_instance_methods", klass)
      methods.each do |meth|
        next if internal_name?(meth)
        index.add_private(build_method_entry(klass, meth, singleton: false))
      end
    end

    # The methods semantic highlighting must NOT tokenize (TextMate colors them),
    # mirroring ruby-lsp's set but sourced from the LIVE mruby VM: Kernel and
    # Module own methods, BOTH public and private. In mruby the bare-call
    # built-ins (puts, p, print, raise, lambda, proc, loop) are Kernel PRIVATE
    # instance methods, and private/module_function are Module private — so
    # public-only reflection misses them. Where mruby differs from CRuby (e.g.
    # no `require`) we correctly differ from ruby-lsp.
    def builtin_special_methods
      set = Set.new
      %w[Kernel Module].each do |k|
        set.merge(reflect_names(@reflect.instance_methods(k), "instance_methods", k))
        set.merge(reflect_names(@reflect.private_instance_methods(k, false),
                                "private_instance_methods", k))
      end
      set
    end

    def close
      @reflect.close
    end

    private

    # Recursively enumerate every class/module reachable from Object.
    # Returns unique fully-qualified names, "Object" included.
    #
    # mruby's constant lookup is lexical+inherited, so constants(X) returns names
    # VISIBLE from X, not only those DEFINED on X. Walked naively this never
    # terminates: Module/Class echo Object's entire constant table, and nested
    # classes echo their siblings (Enumerator::Lazy lists Lazy again) and selves
    # (Errno::ENOMEM lists Errno). Two guards make it terminate while keeping
    # every real namespace:
    #   1. Echo guard — a namespace whose constant set equals Object's full table
    #      is a reflection of the global table (Module/Class); don't descend it.
    #   2. Repeat-component guard — a fully-qualified name with a duplicated path
    #      component (Foo::Foo, Enumerator::Lazy::Lazy) is a self/sibling echo;
    #      skip it.
    def enumerate_namespaces
      object_consts = constant_names("Object").to_set
      seen = { "Object" => true }
      queue = ["Object"]

      until queue.empty?
        current = queue.shift
        consts = constant_names(current)
        # Echo guard: skip descent into the global-table reflectors.
        next if current != "Object" && consts.to_set == object_consts && !object_consts.empty?

        consts.each do |const|
          fq = current == "Object" ? const : "#{current}::#{const}"
          next if seen[fq]
          # Platform (mruby-platform's compile-time facts) is LSP-internal, read
          # to pick the C backend -- never a user-facing symbol.
          next if fq == "Platform" || fq.start_with?("Platform::")
          # Hide internal modules/classes from every surface: starts with "__"
          # but not ending in "__". Covers injected plumbing like __ValueBridge
          # (the bridge's Tagged fallback wrapper, defined from C so the parser-
          # forbidden name can exist). Real dunder constants (__x__) are kept;
          # mruby defines no __x namespaces, so nothing legitimate is lost.
          next if internal_name?(const)

          # Repeat-component guard: kills self/sibling echoes.
          parts = fq.split("::")
          next if parts.size != parts.uniq.size

          seen[fq] = true
          queue << fq
        end
      end

      seen.keys
    end

    def constant_names(namespace)
      reflect_names(@reflect.constants(namespace), "constants", namespace)
    end

    def add_class_entry(index, name)
      return if name == "Object" # Object itself isn't a useful completion target on its own

      # class vs module by the BasicObject invariant on the just-recorded MRO
      # (a class's ancestry contains BasicObject; a module's never does) — same
      # signal Index#vm_class? uses. Pure host logic over reflected data.
      index.add(Entry.new(
        name: name,
        owner: owner_of(name),
        kind: index.vm_class?(name) == false ? :module : :class,
        uri: synthetic_uri(name),
        line: nil,
        params: nil,
        native: false,
        singleton: false,
        doc: nil,
      ))
    end

    # Record the receiver's ordered ancestor chain, used for distance ranking.
    def add_value_constant_entry(index, name)
      index.add(Entry.new(
        name: name, owner: owner_of(name), kind: :constant,
        uri: synthetic_uri(owner_of(name)), line: nil, params: nil,
        native: true, singleton: false, doc: nil
      ))
    end

    # Record the class's declared ivar types from mruby-native-ext-type, if the
    # gem is compiled into this build. `net_schema` returns { :@ivar => [Class,
    # ...] } (Class values arrive as value_bridge name tags). Absent gem -> the
    # op raises in the VM -> bridged exception (or the reflect .so predates the
    # op -> respond_to? is false); either way we skip it. Pure baseline data;
    # a live write still wins downstream (type_inference).
    def record_ivar_schema(index, klass)
      return unless @reflect.respond_to?(:net_schema)
      raw = @reflect.net_schema(klass)
      return if mruby_error?(raw) || !raw.is_a?(Hash) || raw.empty?
      schema = {}
      raw.each do |ivar, types|
        next unless types.is_a?(Array) && !types.empty?
        names = types.map { |t| class_tag_name(t) }.compact
        schema[ivar.to_s] = names unless names.empty?
      end
      index.set_ivar_schema(klass, schema) unless schema.empty?
    end

    def record_ancestors(index, klass)
      chain = @reflect.ancestors(klass)
      if mruby_error?(chain)
        warn_mruby_error("ancestors", klass, chain)
        return
      end
      chain = chain.map { |c| class_tag_name(c) } if chain.is_a?(Array)
      index.set_ancestors(klass, chain) if chain.is_a?(Array) && !chain.empty?
    end

    def add_method_entries(index, klass)
      methods = reflect_names(@reflect.instance_methods(klass), "instance_methods", klass)
      methods.each do |meth|
        next if internal_name?(meth) # internal plumbing (__x), keep dunders (__x__)
        index.add(build_method_entry(klass, meth, singleton: false))
      end
    end

    # Singleton/class methods (File.basename, Math.sqrt). The receiver for these
    # is the class itself; ranked via the singleton route, not ancestry hops.
    def add_singleton_method_entries(index, klass)
      methods = reflect_names(@reflect.singleton_methods(klass), "singleton_methods", klass)
      methods.each do |meth|
        next if internal_name?(meth)
        index.add(build_method_entry(klass, meth, singleton: true))
      end
    end

    # Build one method Entry, resolving its source location + doc uniformly:
    #   C methods   -> CLocator (mrb_open anchor join + addr2line) gives the C
    #                  file, line, and function name; the function name drives
    #                  RDoc-based doc extraction.
    #   Ruby methods-> source_location gives file + line; Prism drives doc.
    # When a C location can't be resolved (no -g, addr2line ??), we keep the
    # synthetic uri and nil doc — graceful, never crash.
    def build_method_entry(klass, meth, singleton:)
      sep = singleton ? "." : "#"
      offset = cfunc_offset(klass, meth, singleton)
      native = !offset.nil?

      if native
        # DEFERRED: no addr2line, no RDoc here. Startup must not pay for
        # locations nobody asked about (1990 entries x subprocess+parse was a
        # 30s first-completion stall). The offset rides on the entry; hover/
        # definition enrich through Index#enrich on demand, memoized.
        uri = synthetic_uri(klass)
        line = nil
        doc = nil
      else
        path, line = source_location(klass, meth, singleton) || [nil, nil]
        uri = path && !path.empty? ? "file://#{path.sub(%r{\Afile://}, '')}" : synthetic_uri(klass)
        # source_location yields the line as a STRING ("54"); the doc table is
        # keyed by Integer start_line -- without to_i every mrblib doc was nil.
        doc = (path && line) ? @doc.ruby_doc(path.sub(%r{\Afile://}, ""), line.to_i) : nil
      end

      Entry.new(
        name: "#{klass}#{sep}#{meth}",
        owner: klass,
        kind: :method,
        uri: uri,
        line: line,
        cfunc_offset: native ? offset : nil,
        params: render_params(klass, meth, singleton),
        native: native,
        singleton: singleton,
        doc: doc,
        from_gem: native ? false : Origin.from_gem?(path, @mruby_root),
        return_type: native ? nil : irep_return_type(klass, meth, singleton),
      )
    end

    # Stage 2: the irep-derived return type of a compiled Ruby method, via the
    # MrubyIrepReflect gem in the VM. nil for C methods, for unmodelled bodies,
    # or when the gem isn't in the build (the bridge degrades to nil). Cheap: one
    # bounded irep read; computed here so queries are a field read, and refreshed
    # wholesale on rebuild (the live VM's current generation).
    def irep_return_type(klass, meth, singleton)
      t = singleton ? @reflect.singleton_return_type(klass, meth) : @reflect.return_type(klass, meth)
      t.is_a?(String) && !t.empty? ? t : nil
    end

    # singleton: methods enumerated via singleton_methods live on the class's
    # SINGLETON class, not its instance class. The flag tells the C bridge to
    # anchor the lookup there (klass's metaclass). Without it the bridge searches
    # the instance class, the method isn't found, and the VM method search walks
    # off into invalid memory -> SIGSEGV. (This is the "anchor to the class the
    # method lives on" rule.)
    def cfunc_offset(klass, meth, singleton)
      return nil unless @anchor_addr
      addr = singleton ? @reflect.singleton_cfunc_addr(klass, meth) : @reflect.cfunc_addr(klass, meth)
      return nil unless addr.is_a?(Integer)
      # THE pointer math, in Ruby: offset = cfunc_addr - anchor_addr. Invariant
      # under PIE/ASLR (both shift by the same load base), equals nm's
      # addr(cfunc) - addr(mrb_open) on the linked image. C did no math.
      off = addr - @anchor_addr
      off if off.is_a?(Integer) && off != 0
    end

    def source_location(klass, meth, singleton)
      loc = singleton ? @reflect.singleton_source_location(klass, meth) : @reflect.source_location(klass, meth)
      return nil unless loc.is_a?(Array)
      # Some builds return [nil] for C methods.
      path = loc[0]
      return nil if path.nil?
      [path, loc[1]]
    end

    # Render the flat [kind, name, ...] pairs into a signature string.
    # The aspec is ALWAYS available: for C methods the reflect ext decodes the
    # method's arg spec DIRECTLY (mruby's own Method#parameters wrongly reports a
    # C method's required args as :opt, since a cfunc proc isn't strict) and
    # yields true req/opt/rest/post/key/block kinds with no names; irep methods
    # come through mruby's parameters with real names on top. So this always
    # renders a signature for a reflectable method: [] is a genuine zero-arg "()"
    # (not nil), and unnamed positional specs get numbered placeholders instead
    # of repeated "arg" noise. nil only on reflection FAILURE.
    def render_params(klass, meth, singleton)
      pairs = singleton ? @reflect.singleton_parameters(klass, meth) : @reflect.parameters(klass, meth)
      return nil unless pairs.is_a?(Array)   # nil only on reflection FAILURE
      ParamFormat.render(pairs)
    end

    # ancestors come back as value_bridge CLASS tags (id + payload=qualified name).
    # The index works in names, so read the payload. Tolerate a bare string/symbol.
    def class_tag_name(c)
      if c.is_a?(ValueBridge::Tagged) then c.payload.to_s
      else c.to_s
      end
    end

    # A reflection op that RAISED in the mruby VM now bridges its exception over
    # as a ValueBridge::Tagged carrying the mruby exception tag (id 8), payload
    # [class_name, message, [backtrace frames]] — instead of the old ambiguous
    # nil. Detect it so a real VM-side failure is visible, not silently swallowed
    # into an incomplete index.
    def mruby_error?(v)
      v.is_a?(ValueBridge::Tagged) &&
        v.tag == ValueBridge::Tagged::EXCEPTION_MRUBY
    end

    # Surface a bridged VM exception. Skipping (not crashing) keeps one bad class
    # from aborting the whole populate, but unlike a blanket rescue the cause is
    # visible: set MRUBY_LSP_DEBUG to see what the VM raised, where.
    def warn_mruby_error(op, subject, tagged)
      return unless ENV["MRUBY_LSP_DEBUG"]
      cls, msg, bt = tagged.payload
      warn "mruby-lsp: #{op}(#{subject}) raised in VM: #{cls}: #{msg}"
      Array(bt).first(5).each { |f| warn "mruby-lsp:   #{f}" }
    end

    # The shared "names list from the VM" path: an Array becomes [String]; a
    # bridged VM exception is logged and treated as empty (skip, don't abort);
    # nil (op declined, no raise) is empty. No blanket rescue — a CRuby-side bug
    # in here SHOULD surface loudly rather than masquerade as "no methods".
    def reflect_names(result, op, subject)
      if mruby_error?(result)
        warn_mruby_error(op, subject, result)
        return []
      end
      (result || []).map(&:to_s)
    end

    # Internal-plumbing name to hide from all surfaces (completion, symbols,
    # ancestry walks): one that starts with "__" but does NOT end with "__".
    # Hides our injected helpers (e.g. the value_bridge fallback module
    # __ValueBridge) and mruby's own __x internals (__gsub_str etc.) while
    # preserving legitimate Ruby dunders -- __send__, __id__, __method__ --
    # which begin AND end with "__" and are real user API. Checks the last
    # "::"-separated component so qualified names judge by their own basename.
    def internal_name?(name)
      s = name.to_s
      base = s.rindex("::") ? s[(s.rindex("::") + 2)..] : s
      base.start_with?("__") && !base.end_with?("__")
    end

    def owner_of(name)
      idx = name.rindex("::")
      idx ? name[0...idx] : "Object"
    end

    def synthetic_uri(name)
      "#{SYNTHETIC_SCHEME}://#{name}"
    end
  end

  # Lazy C-location resolution for native entries: addr2line runs on the FIRST
  # hover/definition of a given method, memoized by Index#enrich. Docs and types
  # are NOT here -- they come from clangd, separately (Index#c_doc / c_return_type).
  # Holds only the .so path — independent of the (closed) VM.
  class NativeResolver
    def initialize(clocator)
      @clocator = clocator
    end

    def resolve(offset)
      return nil unless @clocator
      loc = @clocator.resolve(offset)
      return nil unless loc
      c_func, c_file, c_line = loc
      return nil unless c_file
      {
        uri: "file://#{c_file}",
        line: c_line,
        func: c_func,    # the C function name (addr2line) -> clangd documentSymbol match
        file: c_file,    # the C source path -> clangd didOpen (Stage 3 return type)
      }
    end
  end

end
