# frozen_string_literal: true

require "set"
require "prism"
require_relative "param_format"
require_relative "block_params"
module MrubyLsp
  # An entry in the index. Plain data — no ruby-lsp types. The Reflector (T3.2)
  # populates these from the live VM; the language features (T4.x) read them.
  Entry = Data.define(
    :name,       # String — fully-qualified, "String" or "String#upcase"
    :owner,      # String — class/module the entry lives on, "String"
    :kind,       # Symbol — :class, :module, :method, :constant
    :uri,        # String — file URI or synthetic "mruby-core://String"
    :line,       # Integer or nil — 1-based start line (VM source_location)
    :params,     # String or nil — signature, "(str, encoding = ...)"
    :native,     # Boolean — implemented in C
    :singleton,  # Boolean — a class/singleton method (JSON.parse) vs instance
    :doc,        # String or nil — leading source comment (Ruby via Prism; C via clangd, lazy)
    :range,      # Hash or nil — full 0-based def span {start:{line,character},end:{...}}
    :name_range, # Hash or nil — 0-based span of just the defined NAME token
    :superclass, # String or nil — buffer class's written superclass (qualified name)
    :mixins,     # Array — buffer class/module [[:include|:prepend, "Name"], ...] in source order
    :visibility, # Symbol — :public (default) / :private / :protected, for buffer methods
    :cfunc_offset, # Integer or nil — native method's anchor-relative offset; the
                   # file/line/doc resolve LAZILY (addr2line + RDoc) on first
                   # hover/definition, never at populate (startup must not pay
                   # for locations nobody asked about)
    :from_gem,   # Boolean — defined by a GEM (added) vs mruby core (src/mrblib).
                 # Set structurally where the real path is known (anchored to
                 # MRUBY_ROOT), never inferred from a "/mrbgems/" uri substring.
    :return_type, # String or nil — irep-derived return type for a compiled Ruby
                  # method (Stage 2), set at populate from MrubyIrepReflect. nil
                  # when unknown/unmodelled (-> caller shows nothing, like ruby-lsp).
                  # Buffer-open methods never use this: Stage 1 (AST) wins there.
  ) do
    def initialize(name:, owner:, kind:, uri:, line:, params:, native:, singleton:, doc:, range: nil, name_range: nil, superclass: nil, mixins: [], visibility: :public, cfunc_offset: nil, from_gem: false, return_type: nil)
      super
    end
  end

  # Origin classification: a resolved source path is from a GEM (anything added)
  # unless it lives in mruby CORE (<root>/src or <root>/mrblib). Anchored prefix
  # check against the known mruby root -- NOT a "/mrbgems/" substring, which only
  # catches in-tree core gems and misses path:/gemdir:/github: gems whose source
  # lives outside the tree (e.g. mruby-cbor itself). C-only in practice; Ruby
  # methods get their real path straight from the VM's source_location.
  module Origin
    module_function
    def from_gem?(path, mruby_root)
      return false unless path && mruby_root && !path.empty?
      p = path.sub(%r{\Afile://}, "")
      r = mruby_root.chomp("/")
      !(p.start_with?("#{r}/src/") || p.start_with?("#{r}/mrblib/"))
    end
  end

  class Index
    # Built-in method names (mruby Kernel/Module, public+private) that semantic
    # highlighting suppresses — TextMate already colors them. Sourced from the
    # live VM at populate (empty when degraded). Carried on the index so it
    # survives the atomic swap and is fresh after a rebuild.
    attr_accessor :special_methods

    # Lazy native-location resolver (CLocator + DocExtractor pair), installed at
    # populate. Survives the Reflector (which closes the VM after populate);
    # addr2line and RDoc only need the .so path and C files on disk.
    attr_accessor :native_resolver
    # Stage 3: a CTypeResolver (clangd-backed) for C method return types. Injected
    # by the server after populate; nil -> Stage 3 off (degrade).
    attr_accessor :ctype_resolver

    # Project mruby root, set at populate; anchors Origin.from_gem? path checks.
    attr_accessor :mruby_root

    def initialize
      @entries = Hash.new { |h, k| h[k] = [] }   # name → [Entry] (VM layer)
      @ancestors = {}                            # class name → [ancestor names] (ordered)
      @ivar_schema = {}                          # class name → { "@ivar" => [type names] }
                                                 # declared via mruby-native-ext-type
      @methods_by_owner = Hash.new { |h, k| h[k] = [] } # owner → [Entry] (VM methods)
      @private_by_owner = Hash.new { |h, k| h[k] = [] } # owner → [Entry] (VM private instance methods)
      @dist_cache = {}                           # [receiver, defining_class] → hops
      @special_methods = Set.new
      # Guards the lazy native memos (@enrich_memo / @ctype_memo). Buffer harvest
      # and request handlers both resolve C types OUTSIDE the server mutex, so the
      # memo Hashes can be touched concurrently; this serializes that.
      @memo_mutex = Mutex.new
      @enrich_memo = {}
      @ctype_memo = {}
      @cdoc_memo = {}
      @csig_memo = {}
      @yield_memo = {}        # entry name => [block param name, ...] | nil
      @source_ast_memo = {}   # ruby source uri => parsed Prism AST | nil

      # Buffer layer (T7): per-uri harvested entries from open docs. Consulted
      # FIRST — buffer always wins. order_key ranks uris by mruby's compile order
      # so that, among open tabs, the later-compiled definition wins on collision.
      @buffer_by_uri = {}   # uri → [Entry]
      @buffer_ivar_by_uri = {} # uri → { "Class" => { "@x" => [type names] } }
                               # native_ext_type declared in an OPEN buffer
      @buffer_order = {}    # uri → comparable order key (lower = earlier compiled)

      # Stage 4: return types mined from the test suite (TestHarvester), keyed by
      # the DEFINING method entry's name. Consulted by c_return_type when irep and
      # clangd both come up empty.
      @harvested = {}       # "Owner#method" → rbs type string
    end

    def add(entry)
      @entries[entry.name] << entry
      @methods_by_owner[entry.owner] << entry if entry.kind == :method
    end

    # Private instance-method entries, kept out of the public method table so
    # explicit-receiver lookups never offer them.
    def add_private(entry)
      @private_by_owner[entry.owner] << entry if entry.kind == :method
    end

    # Private instance methods visible from KLASS via its real VM ancestry
    # (so Object sees Kernel#puts/p/print). Used only by bare/implicit-self
    # completion, where private methods are callable without a receiver. Includes
    # buffer-defined private methods and honors buffer undef/remove.
    def private_methods_of(klass)
      ancestors(klass).flat_map do |a|
        tomb = own_tombstones(a)
        vmp = @private_by_owner[a].reject { |e| tomb.include?(method_name(e.name)) }
        buf = {}
        buffer_method_ops(a).each do |op|
          next if op.singleton
          mname = method_name(op.name)
          case op.kind
          when :method then op.visibility == :private ? (buf[mname] = op) : buf.delete(mname)
          when :undef, :remove then buf.delete(mname)
          end
        end
        vmp + buf.values
      end
    end

    # ── buffer layer (T7): buffer always wins ────────────────────────────────

    # Replace the harvested entries for one open document. order_key ranks this
    # uri in mruby's compile order (lower = earlier; later wins on collision).
    def set_buffer(uri, entries, order_key)
      @buffer_by_uri[uri] = entries
      @buffer_order[uri] = order_key
    end

    # Drop a document's buffer entries (didClose).
    def clear_buffer(uri)
      @buffer_by_uri.delete(uri)
      @buffer_order.delete(uri)
      @buffer_ivar_by_uri.delete(uri)
    end

    # Record native_ext_type declarations harvested from an open buffer:
    # { "Class" => { "@x" => [type names] } }. Consulted by ivar_type FIRST
    # (buffer-wins), so a declaration you're typing applies before the compiled
    # VM's. Cleared on didClose via clear_buffer.
    def set_buffer_ivar_schema(uri, schema)
      @buffer_ivar_by_uri[uri] = schema || {}
    end

    # All buffer entries, ordered by compile order then yielded so that the
    # LAST occurrence of a qualified name wins (mruby: later file overrides).
    def buffer_entries
      @buffer_by_uri
        .sort_by { |uri, _| @buffer_order.fetch(uri, [Float::INFINITY]) }
        .flat_map { |_, entries| entries }
    end

    # Buffer entries that name a real symbol (classes/methods/constants/vars) —
    # i.e. NOT the :undef/:remove deletion markers, which are mutation ops, not
    # things that exist. Symbol-facing lookups (resolve/prefix/definitions) use
    # this; the method-table reduction uses buffer_method_ops, which keeps them.
    def symbol_entries
      buffer_entries.reject { |e| e.kind == :undef || e.kind == :remove }
    end

    # Ordered method-table ops (:method additions, :undef/:remove deletions) for
    # one owner, in compile+source order — the input to the reduction.
    def buffer_method_ops(owner)
      buffer_entries.select { |e| (e.kind == :method || e.kind == :undef || e.kind == :remove) && e.owner == owner }
    end

    # The winning buffer entry per qualified name (last in compile order wins).
    def buffer_winners
      win = {}
      symbol_entries.each { |e| win[e.name] = e } # later overwrites earlier
      win
    end

    # Move the live buffer overlay onto another index (used when swapping in a
    # freshly reflected index after a rebuild — open tabs stay authoritative).
    def transfer_buffers_to(other)
      @buffer_by_uri.each do |uri, entries|
        other.set_buffer(uri, entries, @buffer_order[uri])
      end
    end

    # Record a class's ordered ancestor chain (from the VM). Drives distance
    # ranking — a method's usefulness is how few hops its defining class is from
    # the receiver in this chain.
    def set_ancestors(klass, ancestor_names)
      @ancestors[klass] = ancestor_names
    end

    # Record a class's declared ivar schema (mruby-native-ext-type):
    # { "@ivar" => [type name, ...] }. Set at populate from the live VM.
    def set_ivar_schema(klass, schema)
      @ivar_schema[klass] = schema
    end

    # The DECLARED type of an ivar on a class, or nil. Returns a concrete type
    # name only when the declaration names exactly ONE class; a union (>1) is
    # nil — never guessed, same rule as concrete_receiver. The declaration is a
    # baseline: a live write to the ivar (type_inference) wins over it, as
    # dynamic as Ruby. Absent gem / class / ivar -> nil.
    def ivar_type(klass, ivar_name)
      name = ivar_name.to_s
      # Buffer layer first (buffer-wins): a native_ext_type in an open buffer
      # decides — single concrete -> that type, union -> nil (never guessed),
      # and we do NOT fall through to the VM for a class the buffer declares.
      @buffer_ivar_by_uri.each_value do |schema|
        types = schema[klass] && schema[klass][name]
        return (types.is_a?(Array) && types.size == 1) ? types.first : nil if types
      end
      schema = @ivar_schema[klass]
      return nil unless schema
      types = schema[name]
      return nil unless types.is_a?(Array) && types.size == 1
      types.first
    end

    # Ancestors (real MRO order, nearest-first). VM classes use the reflected
    # chain. A buffer-ONLY class/module (the VM never saw it) gets its MRO
    # computed from the buffer's superclass + include/prepend structure, splicing
    # in VM ancestry where the chain reaches a compiled class/module.
    def ancestors(klass)
      vm = @ancestors[klass]
      s = buffer_class_struct(klass)
      if vm
        # VM class: the live MRO is the compiled truth. Splice in any open-buffer
        # reopening (added include/prepend/superclass) so open tabs stay
        # authoritative. ADDITIVE only — we never drop a compiled ancestor,
        # because a module in the VM MRO may come from a file that isn't open in
        # a buffer, and absence from a buffer is not proof of removal.
        return vm unless s
        return merge_buffer_mixins(klass, vm.dup, s)
      end
      return [klass] unless s
      mro = buffer_mro(klass, {})
      mro.empty? ? [klass] : mro
    end

    # Splice a buffer reopening into a class's live VM MRO. Using vm_class? we can
    # now isolate the superclass SPINE (the class entries) from klass's own
    # included modules, so:
    #   prepend M           -> M before self
    #   include M           -> M after self, before the spine
    #   superclass S (same) -> no-op
    #   superclass S (diff) -> REPLACE the old spine with S's ancestry, keeping
    #                          klass's own prepends/includes (clean refactor view)
    # When the old superclass can't be classified (unknown ancestry), we fall back
    # to keeping it (additive) — never dropping a real ancestor we can't prove is
    # the superclass.
    def merge_buffer_mixins(klass, vm_mro, s)
      ctx = klass.include?("::") ? klass.rpartition("::").first : nil
      seed = { klass => true }
      self_i = vm_mro.index(klass) || 0

      prepends = s[:mixins].select { |k, _| k == :prepend }.map { |_, n| n }
      includes = s[:mixins].select { |k, _| k == :include }.map { |_, n| n }

      head = vm_mro[0...self_i]            # VM-prepended modules
      after = vm_mro[(self_i + 1)..] || []
      own_mods = []                        # klass's own included modules
      i = 0
      while i < after.length && vm_class?(after[i]) != true
        own_mods << after[i]
        i += 1
      end
      old_spine = after[i..] || []         # old superclass onward

      new_super = s[:superclass]
      new_super_head = new_super ? resolve_ancestry(new_super, ctx, {}).first : nil
      replacing = !!(new_super && old_spine.first && new_super_head != old_spine.first)

      result = []
      buf_pre = []
      prepends.reverse_each { |m| splice(buf_pre, resolve_ancestry(m, ctx, seed.dup)) }
      splice(result, buf_pre)
      splice(result, head)
      splice(result, [klass])
      includes.reverse_each { |m| splice(result, resolve_ancestry(m, ctx, seed.dup)) }
      splice(result, own_mods)
      if replacing
        splice(result, resolve_ancestry(new_super, ctx, seed.dup))
      else
        splice(result, old_spine)
        splice(result, resolve_ancestry(new_super, ctx, seed.dup)) if new_super
      end
      result
    end

    # Merge all buffer definitions of a class/module name (reopenings): first
    # explicit superclass wins; mixins union in source order.
    def buffer_class_struct(klass)
      defs = buffer_entries.select { |e| (e.kind == :class || e.kind == :module) && e.name == klass }
      return nil if defs.empty?
      {
        kind: defs.any? { |e| e.kind == :class } ? :class : :module,
        superclass: defs.filter_map(&:superclass).first,
        mixins: defs.flat_map { |e| e.mixins || [] },
      }
    end

    # Ruby MRO for a buffer class: reverse(prepends) + self + reverse(includes) +
    # superclass chain (Object by default for a class; nothing for a module).
    # visited guards against cyclic inheritance in half-written code.
    def buffer_mro(klass, visited)
      return [] if visited[klass]
      visited[klass] = true
      s = buffer_class_struct(klass)
      return resolve_ancestry(klass, nil, visited) unless s

      ctx = klass.include?("::") ? klass.rpartition("::").first : nil
      result = []
      prepends = s[:mixins].select { |k, _| k == :prepend }.map { |_, n| n }
      includes = s[:mixins].select { |k, _| k == :include }.map { |_, n| n }
      prepends.reverse_each { |m| splice(result, resolve_ancestry(m, ctx, visited)) }
      splice(result, [klass])
      includes.reverse_each { |m| splice(result, resolve_ancestry(m, ctx, visited)) }
      sup = s[:superclass] || (s[:kind] == :class ? "Object" : nil)
      splice(result, resolve_ancestry(sup, ctx, visited)) if sup
      result
    end

    # Resolve a written superclass/mixin name to its ancestry: VM class/module ->
    # reflected MRO; buffer class -> recurse; unknown -> itself. Tries the name
    # as written, then qualified within the referencing class's namespace.
    def resolve_ancestry(name, ctx_ns, visited)
      return [] unless name
      candidates = [name]
      candidates << "#{ctx_ns}::#{name}" if ctx_ns && !name.include?("::")
      candidates.each do |cand|
        return @ancestors[cand] if @ancestors.key?(cand)
        return buffer_mro(cand, visited) if buffer_class_struct(cand)
      end
      [name]
    end

    def splice(result, names)
      names.each { |n| result << n unless result.include?(n) }
    end

    # The REALITY of method lookup on RECEIVER: the full buffer-aware MRO,
    # current -> oldest, each owner paired with its defining entry (nil where
    # the owner doesn't define METH). RESOLVE-3 holds per owner: resolve()
    # collapses reopenings to the winner; distinct ancestors are the links.
    # singleton: class-method side -- class-side ancestry, then the universal
    # Class/Module machinery queried on the instance side.
    def method_chain(receiver, meth, singleton: false)
      owners = resolve_ancestry(receiver, nil, {})
      sep = singleton ? "." : "#"
      chain = owners.map { |o| [o, resolve("#{o}#{sep}#{meth}").first] }
      if singleton
        chain += %w[Class Module Object Kernel BasicObject]
                 .reject { |o| owners.include?(o) }
                 .map { |o| [o, resolve("#{o}##{meth}").first] }
      end
      chain
    end

    def resolve(name)
      win = buffer_winners
      # Buffer wins: if any open buffer defines this exact name, return ONLY the
      # buffer definition(s) for it; otherwise fall back to the VM layer.
      buf = symbol_entries.select { |e| e.name == name }
      return uniq_winners(buf, win) unless buf.empty?

      @entries[name] || []
    end

    # The VM-layer entries a buffer definition SHADOWS (monkey patching): when
    # an open buffer defines NAME, resolve/definitions return only the buffer
    # winner by design; this exposes the hidden compiled twin for display.
    def shadowed(name)
      return [] unless symbol_entries.any? { |e| e.name == name }

      @entries[name] || []
    end

    # ALL definitions of an exact qualified name, in source/compile order, WITHOUT
    # collapsing to the winner (reopened classes, reassigned constants). resolve
    # keeps only the winner — correct for go-to-def/completion override semantics
    # — but hover lists every definition like ruby-lsp.
    def definitions(name)
      buf = symbol_entries.select { |e| e.name == name }
      return buf unless buf.empty?
      @entries[name] || []
    end

    def prefix(pfx)
      win = buffer_winners
      buf = symbol_entries.select { |e| pfx.empty? || e.name.start_with?(pfx) }
      buf_names = buf.map(&:name).to_set

      vm =
        if pfx.empty?
          @entries.values.flatten
        else
          @entries.each_with_object([]) do |(name, entries), result|
            result.concat(entries) if name.start_with?(pfx)
          end
        end
      # Drop VM entries shadowed by a buffer definition of the same name.
      vm = vm.reject { |e| buf_names.include?(e.name) }
      uniq_winners(buf, win) + vm
    end

    # Methods defined on a given owner (own table only, not inherited), as the
    # PUBLIC/protected table after applying the buffer's ordered mutations over
    # the VM baseline in source order: additions shadow, :undef/:remove drop,
    # a private (re)definition is routed out to private_methods_of, and order is
    # honored (def x; undef x; def x nets to present). Falls back to the raw VM
    # table when no buffer touches this owner (keeps the common path identical).
    def methods_of(owner)
      vm = @methods_by_owner[owner]
      ops = buffer_method_ops(owner)
      return vm if ops.empty?

      table = {}
      order = []
      put = lambda do |key, entry|
        order << key unless table.key?(key)
        table[key] = entry
      end
      drop = lambda do |key|
        table.delete(key)
        order.delete(key)
      end
      vm.each { |e| put.call([e.singleton, method_name(e.name)], e) }
      ops.each do |op|
        key = [op.singleton, method_name(op.name)]
        case op.kind
        when :method
          op.visibility == :private ? drop.call(key) : put.call(key, op)
        when :undef, :remove
          drop.call(key)
        end
      end
      order.map { |k| table[k] }
    end

    # Instance-method names the buffer UNDEFs on this owner — tombstones that
    # block the method even when an ancestor defines it (mruby undef semantics).
    # remove_method is NOT a tombstone: it drops only the own copy and lets an
    # inherited one reappear.
    def own_tombstones(owner)
      t = Set.new
      buffer_method_ops(owner).each do |op|
        next if op.singleton
        mname = method_name(op.name)
        case op.kind
        when :method then t.delete(mname)
        when :undef  then t << mname
        when :remove then t.delete(mname)
        end
      end
      t
    end

    # All instance methods VISIBLE on a receiver: walk its ancestor chain and
    # collect each class's own methods, nearer ancestors first. Deduped by
    # method name keeping the nearest definition (override semantics). An undef
    # tombstone on a class blocks that name on all FARTHER ancestors (mruby
    # undef), unless a nearer class already supplied it.
    def visible_methods(receiver)
      winners = buffer_winners
      seen = {}
      tombstoned = Set.new
      ancestors(receiver).each do |klass|
        methods_of(klass).each do |entry|
          next if entry.singleton
          mname = method_name(entry.name)
          next if tombstoned.include?(mname)
          # The VM decides VISIBILITY (which methods exist on the ancestry), but
          # when the same method is open in a buffer, the buffer entry is the
          # live one: it carries the current file://+line, so hover links and
          # F12 go-to-def land in the editor instead of on a non-navigable
          # mruby-core:// synthetic uri. Overlay the buffer twin when present.
          seen[mname] ||= winners[entry.name] || entry # first (nearest) wins
        end
        own_tombstones(klass).each { |mname| tombstoned << mname unless seen.key?(mname) }
      end
      seen.values
    end

    # Is NAME a class (vs a module), per reflected truth? A class's MRO contains
    # BasicObject; a module's never does (verified against mruby). Reads the cached
    # ancestry the reflector already recorded for EVERY namespace — no new VM call,
    # nothing in C. Falls back to the buffer's declared kind, else nil (unknown).
    def vm_class?(name)
      a = @ancestors[name]
      return a.include?("BasicObject") if a
      s = buffer_class_struct(name)
      s ? s[:kind] == :class : nil
    end

    # The spine a class's CLASS methods inherit through: klass, its buffer
    # superclass(es), then the CLASS entries of its VM MRO (modules excluded —
    # an included module contributes no class methods; only `extend` does). Class
    # methods inherit down the superclass chain, so a subclass sees a compiled
    # parent's `def self.x`.
    def superclass_spine(klass)
      spine = []
      seen = {}
      push = lambda { |k| (spine << k; seen[k] = true) unless seen[k] }
      buffer_superclass_chain(klass).each(&push)
      vm = @ancestors[klass] || (spine.last && @ancestors[spine.last])
      vm&.each { |a| push.call(a) if vm_class?(a) }
      spine
    end

    # Singleton/class-method resolution for a class OBJECT (the `Foo.bar` case).
    def singleton_methods_for(klass)
      result = []
      seen = Set.new
      take = lambda do |entries|
        entries.each do |e|
          mn = method_name(e.name)
          next if seen.include?(mn)
          seen << mn
          result << e
        end
      end
      superclass_spine(klass).each do |k|
        take.call(methods_of(k).select(&:singleton))
        take.call(extended_instance_methods(k))
      end
      %w[Class Module Object Kernel].each { |m| take.call(methods_of(m).reject(&:singleton)) }
      result
    end

    # The class's OWN class methods (def self.x + VM singletons), not inherited.
    def singleton_methods_of(receiver)
      methods_of(receiver).select(&:singleton)
    end

    # klass, then its buffer superclass, that class's buffer superclass, ...
    # stopping when the parent isn't a buffer class (its class methods live in the
    # VM, not isolable from the flat MRO). Cycle-guarded.
    def buffer_superclass_chain(klass)
      chain = []
      seen = {}
      cur = klass
      while cur && !seen[cur]
        seen[cur] = true
        chain << cur
        s = buffer_class_struct(cur)
        cur = s && s[:superclass]
      end
      chain
    end

    # Instance methods brought onto a class/module as SINGLETON methods via
    # `extend M` in a buffer (M's full instance-method set), re-presented as
    # singletons of `klass`. `extend self` targets the module itself.
    def extended_instance_methods(klass)
      s = buffer_class_struct(klass)
      return [] unless s
      mods = s[:mixins].select { |k, _| k == :extend }.map { |_, n| n }
      return [] if mods.empty?
      out = []
      seen = Set.new
      mods.each do |m|
        target = (m == :__self__) ? klass : m
        visible_methods(target).each do |e|
          next if e.singleton
          mn = method_name(e.name)
          next if seen.include?(mn)
          seen << mn
          out << e.with(name: "#{klass}.#{mn}", owner: klass, singleton: true)
        end
      end
      out
    end

    # Distance of a method's defining class from the receiver, in ancestor hops.
    # 0 = defined on the receiver itself. nil = not in the chain. Memoized.
    def method_distance(receiver, defining_class)
      key = [receiver, defining_class]
      return @dist_cache[key] if @dist_cache.key?(key)

      @dist_cache[key] = ancestors(receiver).index(defining_class)
    end

    # Enrich a native entry with its real C file/line/doc, on demand, memoized
    # by offset. Entries are immutable — callers use the RETURNED entry. Without
    # a resolver (degraded) the entry passes through with its synthetic uri.
    def enrich(entry)
      if entry.respond_to?(:cfunc_offset) && entry.cfunc_offset && @native_resolver
        info = @memo_mutex.synchronize { @enrich_memo[entry.cfunc_offset] ||= @native_resolver.resolve(entry.cfunc_offset) }
        return entry unless info
        return entry.with(uri: info[:uri] || entry.uri, line: info[:line] || entry.line,
                          from_gem: info[:uri] ? Origin.from_gem?(info[:uri], @mruby_root) : entry.from_gem)
      end

      # A class/module reflected from the VM carries only a synthetic uri (no
      # Ruby source_location is recorded for the class itself). Borrow the
      # definition site of its OWN #initialize — the cfunc registered with
      # mrb_define_method[_id](cls, "initialize" | MRB_SYM(initialize), fn), which
      # IS where a C class is defined — so hover links and F12 land on real
      # source. The lookup is by the reflected method NAME, so it's agnostic to
      # the _id vs string define form; it resolves for C (cfunc -> addr2line) and
      # Ruby/mrblib (irep -> file uri) initializers alike. No own initialize ->
      # any own method's site; none resolvable -> the entry stays synthetic.
      if (entry.kind == :class || entry.kind == :module) && !entry.uri.to_s.start_with?("file://")
        site = class_definition_site(entry.name)
        return entry.with(uri: site.uri, line: site.line,
                          from_gem: Origin.from_gem?(site.uri, @mruby_root)) if site
      end
      entry
    end

    # The real-source location to stand in for a VM class's definition: its OWN
    # #initialize — the constructor, the C function that defines the class.
    # Returns an ENRICHED entry whose uri is file:// (caller copies uri/line), or
    # nil. ONLY initialize, never some other own method: a gem that merely
    # monkey-patches a method onto a core class (e.g. Integer#to_json from a json
    # gem) is "own" by owner but lives in unrelated source — borrowing it would
    # point Integer at the json gem. A class with no own initialize (Integer,
    # Float, NilClass, ...) keeps its synthetic uri: better no location than a
    # misleading one. initialize is private, so check both own-method tables.
    def class_definition_site(class_name)
      own = @methods_by_owner[class_name] + @private_by_owner[class_name]
      init = own.find { |e| e.name == "#{class_name}#initialize" }
      return nil unless init
      located = enrich(init)
      located.uri.to_s.start_with?("file://") ? located : nil
    end

    # Stage 4 (lazy): the Ruby class a C method returns, via clangd. Computed
    # only when a C method is actually used as a typed receiver (type inference),
    # never at populate. Memoized per offset, reusing enrich's native-location
    # memo to get the C file+func (addr2line). nil -> unknown / clangd off.
    def c_return_type(entry)
      return entry.return_type if entry.return_type   # buffer/irep already typed it
      # Stage 3: clangd reads the C return constructors. Stage 4: a type observed
      # in the test suite -- the fallback for exactly the methods clangd cannot
      # decide (mixed/helper returns like io_read). Applies even when clangd is
      # off, and to Ruby methods whose irep type was indeterminate.
      clangd_return_type(entry) || @harvested[entry.name]
    end

    def clangd_return_type(entry)
      return nil unless @ctype_resolver
      return nil unless entry.respond_to?(:cfunc_offset) && entry.cfunc_offset && @native_resolver
      off = entry.cfunc_offset
      @memo_mutex.synchronize do
        return @ctype_memo[off] if @ctype_memo.key?(off)
        info = (@enrich_memo[off] ||= @native_resolver.resolve(off))
        @ctype_memo[off] = info && @ctype_resolver.resolve(info[:file], info[:func])
      end
    end

    # Merge test-harvested return types ({ "ObservedClass#method" => type }) into
    # the index. The harvester keys by the receiver class it SAW in a test (read
    # observed through a File -> "File#read"), but read is defined on IO and
    # inherited; the VM dispatches it via the ancestry. So resolve each observed
    # key to the entry that actually DEFINES the method and key the type by that,
    # making it apply to every class in the method's ancestry -- IO, File, Socket.
    # A class/method the VM doesn't have is dropped (never invented).
    def merge_test_types(raw)
      raw.each do |key, type|
        cls, meth = key.split("#", 2)
        next unless cls && meth && !meth.empty?
        entry = visible_methods(cls).find { |e| method_name(e.name) == meth }
        @harvested[entry.name] = type if entry
      end
      self
    end

    # C method's leading doc comment, via clangd (lazy, memoized per offset).
    # Reuses enrich's native-location memo for the C file+func. nil -> no comment
    # or clangd off. VERBATIM -- a later rbs pass reads annotations from it.
    def c_doc(entry)
      return nil unless @ctype_resolver
      return nil unless entry.respond_to?(:cfunc_offset) && entry.cfunc_offset && @native_resolver
      off = entry.cfunc_offset
      @memo_mutex.synchronize do
        return @cdoc_memo[off] if @cdoc_memo.key?(off)
        info = (@enrich_memo[off] ||= @native_resolver.resolve(off))
        @cdoc_memo[off] = info && @ctype_resolver.doc(info[:file], info[:func])
      end
    end

    # The C method's signature with its REAL parameter names, parsed from the
    # function's mrb_get_args call via clangd (lazy, memoized per offset). nil ->
    # not a C method, no parseable mrb_get_args, or clangd off; the caller then
    # falls back to entry.params (the aspec-derived, argN-placeholder signature).
    # Single-method cost (one clangd documentSymbol per C file, then memoized),
    # reached only through display_params -- the ONE seam every feature renders
    # parameters through, so none of them can disagree on a method's signature.
    def c_signature(entry)
      return nil unless @ctype_resolver
      return nil unless entry.respond_to?(:cfunc_offset) && entry.cfunc_offset && @native_resolver
      off = entry.cfunc_offset
      @memo_mutex.synchronize do
        return @csig_memo[off] if @csig_memo.key?(off)
        info = (@enrich_memo[off] ||= @native_resolver.resolve(off))
        specs = info && @ctype_resolver.arg_specs(info[:file], info[:func])
        @csig_memo[off] = specs && ParamFormat.render(specs)
      end
    end

    # The parameter signature a feature should DISPLAY for an entry: a C method's
    # REAL names (mrb_get_args, via c_signature) when resolvable, else the
    # aspec-derived entry.params. The single source of truth for "what params do
    # we show", shared by hover, signatureHelp, AND completion, so the same
    # method never renders one way in the completion list and another on hover.
    # Non-method entries carry no signature -- their params pass through.
    def display_params(entry)
      return entry.params unless entry.kind == :method

      c_signature(entry) || entry.params
    end

    # The names a method gives its block, read from the method's OWN source -- its
    # `yield` / block-call in Ruby, or mrb_yield / mrb_funcall in C (see
    # BlockParams). -> ["a", "b"] | nil (doesn't yield, or yields nothing
    # nameable). Drives the block-scaffold completion. Lazy + memoized per method;
    # the source is the truth, exactly like c_signature is for parameters.
    def yield_params(entry)
      return nil unless entry.respond_to?(:kind) && entry.kind == :method

      @memo_mutex.synchronize do
        key = entry.name
        return @yield_memo[key] if @yield_memo.key?(key)

        @yield_memo[key] = compute_yield_params(entry)
      end
    end

    def compute_yield_params(entry)
      # C method: read its mrb_yield / mrb_funcall via clangd, like c_signature.
      if @ctype_resolver && entry.respond_to?(:cfunc_offset) && entry.cfunc_offset && @native_resolver
        info = (@enrich_memo[entry.cfunc_offset] ||= @native_resolver.resolve(entry.cfunc_offset))
        return info && @ctype_resolver.yield_args(info[:file], info[:func])
      end
      # Ruby method: parse its source file, find the def, read its block-call.
      ruby_yield_params(entry)
    end

    # The source is the file:// .rb the VM recorded (mrblib / project file) or a
    # SAVED open buffer; unsaved buffer edits to the yielding method aren't seen.
    def ruby_yield_params(entry)
      uri = entry.uri
      return nil unless uri&.start_with?("file://") && uri.end_with?(".rb")

      ast = source_ast(uri) or return nil
      def_node = find_def(ast, entry.line, method_name(entry.name)) or return nil
      BlockParams.from_ruby(def_node)
    end

    def source_ast(uri)
      return @source_ast_memo[uri] if @source_ast_memo.key?(uri)

      @source_ast_memo[uri] =
        begin
          path = uri.sub(%r{\Afile://}, "")
          File.file?(path) ? Prism.parse(File.read(path)).value : nil
        rescue StandardError
          nil
        end
    end

    # The DefNode named meth, preferring the one starting on `line` (the
    # VM-recorded def line), else the first by that name.
    def find_def(ast, line, meth)
      matches = []
      stack = [ast]
      until stack.empty?
        node = stack.shift
        next unless node.is_a?(Prism::Node)

        matches << node if node.is_a?(Prism::DefNode) && node.name.to_s == meth
        stack.concat(node.compact_child_nodes)
      end
      (line && matches.find { |d| d.location.start_line == line }) || matches.first
    end

    # All entries of a variable kind (:ivar/:cvar/:gvar), optionally owner-scoped.
    # ivars/cvars/gvars exist ONLY in the buffer layer (the VM table holds no
    # variable entries) -- but merge both layers anyway so this stays correct if
    # reflection ever grows them. Buffer first; callers dedup by name.
    def variables(kind, owner: nil)
      (symbol_entries + @entries.values.flatten).select do |e|
        e.kind == kind && (owner.nil? || e.owner == owner)
      end
    end

    # Rewrite native entries with their batch-resolved C locations (uri + line
    # only; the doc stays lazy -- RDoc parsing is the expensive half).
    # - Collects offsets from EVERY table first and primes them in ONE
    #   addr2line process. @private_by_owner entries never enter @entries, so
    #   priming from @entries alone left them as cache misses = one addr2line
    #   SPAWN each (851ms of a 910ms apply step).
    # - Replacements go through an identity map so the same rewritten object
    #   lands in every table (entries are immutable and shared across tables).
    def apply_native_locations(locator)
      tables = [@entries, @methods_by_owner, @private_by_owner]
      offsets = tables.flat_map { |t| t.each_value.flat_map { |l| l.filter_map { |e| e.respond_to?(:cfunc_offset) ? e.cfunc_offset : nil } } }
      locator.prime(offsets)

      replacement = {}.compare_by_identity
      relocate = lambda do |e|
        next e unless e.respond_to?(:cfunc_offset) && e.cfunc_offset
        replacement[e] ||= begin
          loc = locator.resolve(e.cfunc_offset) # primed -- pure cache hit
          if loc && (file = loc[1])
            e.with(uri: "file://#{file}", line: loc[2], from_gem: Origin.from_gem?(file, @mruby_root))
          else
            e
          end
        end
      end
      tables.each { |table| table.each_value { |list| list.map! { |e| relocate.call(e) } } }
    end

    def size = @entries.values.sum(&:size)
    def empty? = @entries.empty?

    private

    # Given buffer entries for a name (possibly several across tabs) and the
    # global winner map, return only the compile-order winner(s), deduped.
    def uniq_winners(buf, win)
      buf.select { |e| win[e.name].equal?(e) }.uniq
    end

    def method_name(qualified)
      # Instance methods use "Owner#meth", singletons use "Owner.meth".
      sep = qualified.index("#") || qualified.index(".")
      sep ? qualified[(sep + 1)..] : qualified
    end
  end
end
