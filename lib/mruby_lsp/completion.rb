# frozen_string_literal: true

require "prism"
require_relative "scope_resolver"
require_relative "locator"
require_relative "type_inference"

module MrubyLsp
  # T4.1 — completion. Prism (never regex) finds the node at the cursor; the
  # index (live VM, T3.2) supplies candidates. Output is sorted by USEFULNESS =
  # literal distance from the scope in play:
  #   methods:    ancestor-hop distance of the defining class from the receiver
  #               (own = 0, mixed-in modules next, Object/Kernel/BasicObject last)
  #   singletons: receiver's own class methods first, universal Module/Class/
  #               Object machinery last (ancestry is meaningless for singletons)
  #   constants:  namespace distance from the cursor's nesting (current scope
  #               first, enclosing scopes outward, top-level last)
  # The order is locked with sortText (zero-padded tier+name).
  module Completion
    module_function

    KIND_METHOD   = 2
    KIND_CLASS    = 7
    KIND_MODULE   = 9
    KIND_CONSTANT = 21

    # Universal receivers whose methods are the low-priority floor.
    UNIVERSAL = %w[Object Kernel BasicObject].freeze
    UNIVERSAL_SINGLETON = %w[Module Class Object Kernel BasicObject].freeze

    def items(document, position, index)
      result = Locator.locate(document.ast.value, document.text, position)
      return [] unless result&.node

      node = result.node
      range = replace_range(node)
      case node
      when Prism::ConstantReadNode
        constant_items(node.name.to_s, result.nesting, index, range)
      when Prism::ConstantPathNode
        constant_path_items(node, result.nesting, index, range)
      when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
           Prism::InstanceVariableTargetNode
        variable_items(:ivar, node.name.to_s, result.nesting, index, range)
      when Prism::ClassVariableReadNode, Prism::ClassVariableWriteNode,
           Prism::ClassVariableTargetNode
        variable_items(:cvar, node.name.to_s, result.nesting, index, range)
      when Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode,
           Prism::GlobalVariableTargetNode
        variable_items(:gvar, node.name.to_s, result.nesting, index, range)
      when Prism::CallNode
        cursor = Locator.position_to_byte_offset(document.text, position)
        call_items(node, index, range, result.nesting || [], document, cursor, sclass: result.sclass)
      else
        # A lone sigil (`@`, `@@`, `$`) parses to nothing useful under error
        # recovery; the trigger characters still fire a request. Dispatch on the
        # 1-2 chars before the cursor -- trigger-char routing, not parsing.
        sigil_fallback(document, position, result&.nesting || [], index)
      end
    end

    def sigil_fallback(document, position, nesting, index)
      off = Locator.position_to_byte_offset(document.text, position)
      before = document.text.byteslice([off - 2, 0].max, [off, 2].min)
      if before.end_with?("@@") then variable_items(:cvar, "@@", nesting, index)
      elsif before.end_with?("@") then variable_items(:ivar, "@", nesting, index)
      elsif before.end_with?("$") then variable_items(:gvar, "$", nesting, index)
      else []
      end
    end

    # ivars/cvars are scoped to the enclosing class; gvars are global. Entries
    # come from buffer harvests (names carry the sigil). Dedup -- one entry per
    # write site.
    def variable_items(kind, prefix, nesting, index, range = nil)
      owner = kind == :gvar ? nil : (nesting.empty? ? "Object" : nesting.join("::"))
      index.variables(kind, owner: owner)
           .select { |e| e.name.start_with?(prefix) }
           .uniq(&:name)
           .sort_by(&:name)
           .map { |e| local_item(e.name, range) }
    end

    # The 0-based range of the partial identifier being completed, so the client
    # replaces exactly that span (ruby-lsp ships this as textEdit.range; without
    # it the editor's own word heuristic can mishandle ! and ? method names).
    # For a CallNode it's the message token; for a constant it's the name; nil
    # when there's no token (e.g. a bare `receiver.`), in which case the caller
    # omits textEdit and the client inserts at the cursor.
    def replace_range(node)
      loc =
        case node
        when Prism::CallNode then node.message_loc
        when Prism::ConstantReadNode then node.location
        when Prism::ConstantPathNode then (node.name ? node.name_loc : nil)
        end
      return nil unless loc
      {
        start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
      }
    end

    # ── constants: ranked by namespace distance from nesting ──────────────────

    def constant_items(prefix, nesting, index, range = nil)
      ranked = ranked_constants(prefix, nesting, index)
      ranked.map { |tier, e| constant_item(e, tier, range) }
    end

    def constant_path_items(node, nesting, index, range = nil)
      parent_name = node.parent ? constant_path_name(node.parent) : nil
      partial = node.name ? node.name.to_s : ""
      full_prefix = parent_name ? "#{parent_name}::#{partial}" : partial
      ranked = ranked_constants(full_prefix, nesting, index)
      ranked.map { |tier, e| constant_item(e, tier, range) }
    end

    # Returns [[tier, entry], ...] with tier = namespace distance bucket.
    def ranked_constants(prefix, nesting, index)
      matches = index.prefix(prefix).select { |e| %i[class module constant].include?(e.kind) }.uniq(&:name)

      matches.map do |e|
        [constant_tier(e.name, nesting), e]
      end.sort_by { |tier, e| [tier, e.name] }
    end

    # Distance bucket: 0 = defined in the current full nesting, then one bucket
    # per enclosing scope walking outward, top-level last.
    def constant_tier(name, nesting)
      owner = name.include?("::") ? name[0...name.rindex("::")] : "Object"
      return 0 if nesting.empty? && owner == "Object"

      # Walk nesting innermost→outermost; nearer enclosing scope = lower tier.
      nesting.length.downto(0) do |i|
        scope = nesting[0...i].join("::")
        scope = "Object" if scope.empty?
        return (nesting.length - i) if owner == scope
      end
      nesting.length + 1 # top-level / elsewhere
    end

    # ── methods: ranked by ancestor-hop distance ──────────────────────────────

    def call_items(node, index, range = nil, nesting = [], document = nil, cursor = nil, sclass: false)
      prefix = node.message.nil? ? "" : node.name.to_s
      if cursor && node.message_loc &&
         !(cursor > node.message_loc.start_offset && cursor <= node.message_loc.end_offset)
        prefix = "" # cursor at the dot; the parsed message is recovery debris
        range = nil # and its token range is on another line — never textEdit it
      end
      recv = node.receiver
      # A CONSTANT receiver is usually a class object -> its class methods
      # (Foo.bar). But a VALUE constant (HEX_CHARS = "...") is an instance of its
      # value's type -> instance methods. Any other receiver (literal, Foo.new, a
      # typed local) is an instance.
      if recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)
        vt = TypeInference.infer_constant(recv, document, index)
        if vt
          klass = nil; owner = vt           # value constant -> instance methods
        else
          klass = basic_type(recv); owner = nil  # class constant -> class methods
        end
      else
        klass = nil; owner = receiver_type(recv, document, index)
      end
      # Inferred names are as WRITTEN (`TagDSL`), index entries are canonical
      # (`CBOR::TagDSL`) -- resolve through the cursor's nesting, exactly like a
      # constant read at that position would resolve. Without this, any local
      # typed to a nested class completes to nothing.
      klass = resolve_owner(klass, nesting, index) if klass
      owner = resolve_owner(owner, nesting, index) if owner
      # Bare prefix inside `class << self`: implicit self IS the class object.
      # Anchor to the enclosing class and take the existing singleton arm --
      # entries AND ranking (instance methods are NOT callable there).
      klass = nesting.join("::") if recv.nil? && sclass && !nesting.empty? && !klass

      entries =
        if klass
          # Class object: its class methods (own + buffer-inherited + extended) and
          # the universal Class/Module/Object machinery.
          index.singleton_methods_for(klass)
        elsif owner
          # Known instance receiver: its visible instance methods (own + inherited).
          index.visible_methods(owner)
        elsif recv.nil? && !nesting.empty?
          # Bare prefix inside a class/module: offer that class's visible methods
          # (own + inherited via the VM MRO) plus true globals — anchored to the
          # cursor's scope, NOT a sweep of every namespace.
          enclosing = nesting.join("::")
          (index.visible_methods(enclosing) +
           ScopeResolver::GLOBAL_OWNERS.flat_map { |o| index.methods_of(o) })
            .reject(&:singleton) + index.private_methods_of(enclosing)
        elsif recv.nil?
          # Bare prefix at top level: globals only (Object/Kernel/BasicObject),
          # not every instance method in the VM. Includes Kernel's PRIVATE
          # instance methods (puts, p, print, raise) — callable without a receiver.
          ScopeResolver::GLOBAL_OWNERS.flat_map { |o| index.methods_of(o) }
            .reject(&:singleton) + index.private_methods_of("Object")
        else
          # An explicit receiver whose type we could NOT resolve (e.g. a C method
          # whose return type isn't statically provable). We don't know what it
          # is, so offer nothing — never the global/private floor, which is
          # meaningless on an explicit receiver and was the "junk completions" bug.
          []
        end

      local_names =
        if recv.nil? && document && cursor
          locals_at(document, cursor).select { |n| n.start_with?(prefix) }
        else
          []
        end

      matching = entries.select { |e| method_name(e.name).start_with?(prefix) }
      # initialize is ALWAYS private in Ruby/mruby regardless of declared
      # visibility; never offer it on an explicit receiver (it reaches here
      # because method tables and buffer harvests carry it as a plain entry).
      matching = matching.reject { |e| method_name(e.name) == "initialize" } if recv
      # Dedup by the short method name (Owner#m and Other#m are the same label to
      # the user). For a known receiver, visible_methods already deduped by
      # nearest-override; this guards the unknown-receiver all-methods branch.
      matching = matching.uniq { |e| method_name(e.name) }

      # Ranking anchor: an explicit receiver's class, or -- for a bare prefix
      # inside a class body -- the ENCLOSING class (implicit self). Without
      # this, bare completions ranked everything tier 0 and the user's own
      # methods alphabetically interleaved with Kernel/Object noise.
      rank_owner = owner || (recv.nil? && !nesting.empty? ? nesting.join("::") : nil)
      ranked = matching.map { |e| [klass ? singleton_tier(klass, e) : method_tier(rank_owner, e, index), e] }
      # All definer files along the receiver's chain per item ("string.c,
      # compar.rb, class.c" for ==) -- the redefinition reality in the LIST.
      anchor = klass || rank_owner
      sep = klass ? "." : "#"
      local_names.map { |n| local_item(n, range) } +
        ranked.sort_by { |tier, e| [tier, sub_tier(e), method_name(e.name)] }
              .map { |tier, e| method_item(e, tier, range, files: definer_files(anchor, e, sep, index)) }
    end

    # Local variables (incl. def/block params) visible at the cursor: collect
    # Prism `locals` from the innermost scope chain -- through blocks/lambdas
    # (they close over the enclosing scope) and stopping at the first hard
    # boundary (def/class/module/sclass/program). Pure AST, declaration-complete.
    def locals_at(document, cursor)
      chain = []
      walk_containing(document.ast.value, cursor, chain)
      names = []
      chain.reverse_each do |node| # innermost first
        case node
        when Prism::BlockNode, Prism::LambdaNode
          names.concat(node.locals.map(&:to_s))
        when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode,
             Prism::SingletonClassNode, Prism::ProgramNode
          names.concat(node.locals.map(&:to_s))
          break
        end
      end
      names.uniq
    end

    def walk_containing(node, offset, chain)
      loc = node.location
      return unless offset >= loc.start_offset && offset <= loc.end_offset
      chain << node
      node.child_nodes.each { |c| walk_containing(c, offset, chain) if c }
    end

    # Resolve a written class name to its canonical index name via the cursor's
    # nesting (Foo inside A::B -> A::B::Foo, A::Foo, Foo -- first that exists).
    def resolve_owner(name, nesting, index)
      entries = ScopeResolver.constant(name, nesting || [], index)
      entries && !entries.empty? ? entries.first.name : name
    end

    # sortText "00_" puts locals above every method tier; kind 6 = Variable.
    def local_item(name, range)
      item = { label: name, kind: 6, sortText: "00!#{name}",
               filterText: name }
      item[:textEdit] = { range: range, newText: name } if range
      item
    end

    # Class-method ranking: the receiver class's own (and extended) methods first,
    # universal Class/Module/Object/Kernel machinery last.
    def singleton_tier(klass, entry)
      entry.owner == klass ? 0 : 99
    end

    # Tier for an instance method: ancestor hop distance of its owner from the
    # receiver. Universal floor (Object/Kernel/BasicObject) forced to the bottom.
    def method_tier(receiver, entry, index)
      return 0 unless receiver # unknown receiver: flat, name-sorted

      return 99 if UNIVERSAL.include?(entry.owner)

      dist = index.method_distance(receiver, entry.owner)
      dist.nil? ? 98 : dist
    end

    # ── item builders ─────────────────────────────────────────────────────────

    def constant_item(entry, tier, range = nil)
      kind = case entry.kind
             when :module then KIND_MODULE
             when :constant then KIND_CONSTANT
             else KIND_CLASS
             end
      label = short_name(entry.name)
      item = {
        label: label,
        labelDetails: { description: source_file(entry.uri) }.compact,
        kind: kind,
        filterText: label,
        sortText: sort_text(tier, label),
        data: { owner_name: entry.owner },
      }
      item[:textEdit] = { range: range, newText: label } if range
      item
    end

    # Every file along ANCHOR's chain that defines ENTRY's method, nearest
    # first. Falls back to the entry's own file when the anchor is unknown.
    def definer_files(anchor, entry, sep, index)
      return nil unless anchor

      meth = method_name(entry.name)
      files = index.method_chain(anchor, meth, singleton: sep == ".")
                   .filter_map { |_, e| source_file(e.uri) if e }.uniq
      files.empty? ? nil : files.join(", ")
    end

    def method_item(entry, tier, range = nil, files: nil)
      name = method_name(entry.name)
      item = {
        label: name,
        labelDetails: { detail: entry.params, description: files || source_file(entry.uri) }.compact,
        kind: KIND_METHOD,
        filterText: name,
        sortText: sort_text(tier, name, sub_tier(entry)),
        # name: the index resolve key -- completionItem/resolve re-finds the
        # entry by it (anchored, never by bare method name).
        data: { name: entry.name, owner_name: entry.owner, native: entry.native },
      }
      item[:textEdit] = { range: range, newText: name } if range
      item[:documentation] = { kind: "markdown", value: entry.doc } if entry.doc && !entry.doc.empty?
      item
    end

    # ── receiver typing (literals + constants only; no unsound inference) ──────

    # Receiver class for method resolution. `document` (optional) enables local-
    # variable type inference; without it only context-free types are resolved.
    def receiver_type(receiver, document = nil, index = nil)
      # The receiver class for METHOD RESOLUTION, so a harvested nilable type
      # narrows here (String? -> String): every caller -- completion, hover,
      # definition, signature help, scope resolution -- looks methods up on the
      # result, and you never dispatch on the nil arm. A real union -> nil (no
      # single receiver). Bare types pass through. Hover-over-a-variable shows the
      # full type via infer_local directly, not through here.
      TypeInference.concrete_receiver(
        basic_type(receiver) ||
          (if document
             case receiver
             when Prism::LocalVariableReadNode
               TypeInference.infer_local(receiver.name, receiver.location.start_offset, document, index)
             when Prism::InstanceVariableReadNode
               TypeInference.infer_variable(:ivar, receiver.name.to_s, receiver.location.start_offset, document, index)
             when Prism::ClassVariableReadNode
               TypeInference.infer_variable(:cvar, receiver.name.to_s, receiver.location.start_offset, document, index)
             when Prism::GlobalVariableReadNode
               TypeInference.infer_variable(:gvar, receiver.name.to_s, receiver.location.start_offset, document, index)
             when Prism::CallNode
               # Return type of the method it names: a buffer def (Stage 1) or, for
               # a compiled VM method, its irep-derived Entry#return_type (Stage 2).
               # `Foo.new` was already resolved by basic_type above.
               TypeInference.infer_call(receiver, document, index)
             end
           end)
      )
    end

    # Context-free types: literals, constants, and `Foo.new`. No document needed.
    def basic_type(receiver)
      case receiver
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::IntegerNode      then "Integer"
      when Prism::FloatNode        then "Float"
      when Prism::RationalNode     then "Rational"
      when Prism::ImaginaryNode    then "Complex"
      when Prism::ArrayNode        then "Array"
      when Prism::HashNode         then "Hash"
      when Prism::TrueNode         then "TrueClass"
      when Prism::FalseNode        then "FalseClass"
      when Prism::NilNode          then "NilClass"
      when Prism::RangeNode        then "Range"
      when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode then "Regexp"
      when Prism::LambdaNode       then "Proc"
      when Prism::ConstantReadNode then receiver.name.to_s
      when Prism::ConstantPathNode then constant_path_name(receiver)
      when Prism::CallNode
        # `Foo.new` is an instance of Foo (the common constructor pattern).
        if receiver.name == :new && receiver.receiver
          basic_type(receiver.receiver)
        end
      end
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    # Sub-tier within a distance tier: methods a GEM bolts onto a class rank
    # after core/own definitions at the same distance (mruby-pack's String#unpack
    # after core String methods). Origin is tagged structurally at harvest
    # (Entry#from_gem, anchored to MRUBY_ROOT) -- NOT a "/mrbgems/" uri substring,
    # which only caught in-tree core gems and missed path:/gemdir: gems living
    # outside the tree (mruby-cbor itself). "unpack before upcase" settled this.
    def sub_tier(entry) = entry.from_gem ? 1 : 0

    def sort_text(tier, name, sub = 0) = format("%02d%d_%s", tier, sub, name)

    def method_name(qualified)
      sep = qualified.index("#") || qualified.index(".")
      sep ? qualified[(sep + 1)..] : qualified
    end

    def short_name(qualified) = qualified.split("::").last

    # Pull the bare source filename for labelDetails.description, mirroring
    # ruby-lsp's "string.rbs"/"string.c" convention. Synthetic uris -> nil.
    def source_file(uri)
      return nil unless uri
      return nil if uri.start_with?("mruby-core://")

      File.basename(uri.sub(%r{\Afile://}, ""))
    end

    def constant_path_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = node.parent ? constant_path_name(node.parent) : nil
        parent ? "#{parent}::#{node.name}" : node.name.to_s
      end
    end
  end
end
