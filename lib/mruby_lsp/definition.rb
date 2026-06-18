# frozen_string_literal: true

require "prism"
require_relative "scope_resolver"
require_relative "locator"
require_relative "completion"

module MrubyLsp
  # T4.3 — go-to-definition. Resolves the node at the cursor to index entries
  # (the live VM, via T3.2) and returns their source locations. Owner-anchored:
  # a method is resolved against the class it lives on, never by bare name alone.
  #
  # Location sources, by entry:
  #   - Ruby-defined methods: uri = file://..., line from source_location
  #   - C-defined methods:    uri = mruby-core://Class (synthetic). Real C source
  #     locations come from addr2line over the reflect_so (CLocator) — wired at
  #     integration; until then the synthetic uri anchors hover/definition to the
  #     owning class rather than pointing nowhere.
  module Definition
    module_function

    def locations(document, position, index)
      result = Locator.locate(document.ast.value, document.text, position)
      return [] unless result&.node

      entries = resolve_entries(result.node, result.parent, index, result.nesting || [], document)
      # For methods, return the FULL redefinition chain (nearest first): with
      # multiple locations the editor opens its inline peek widget under the
      # cursor instead of jumping -- the whole super-walk in one view.
      entries = expand_to_chain(result, entries, index, document)
      # Lazy native locations: addr2line runs for exactly these entries, now
      # that a jump was requested. Memoized in the index.
      entries.filter_map { |e| location_for(index.enrich(e)) }
    end

    # Nearest entry first, then every other definer along the receiver's
    # chain. Non-method targets and unknown receivers pass through unchanged.
    # super/forwarding-super resolves from the PARENT down (what super sees).
    def expand_to_chain(result, entries, index, document)
      node = result.node
      nesting = result.nesting || []
      chain =
        case node
        when Prism::SuperNode, Prism::ForwardingSuperNode
          def_node = result.def_node
          if def_node
            owner = nesting.empty? ? "Object" : nesting.join("::")
            full = index.method_chain(owner, def_node.name.to_s,
                                      singleton: result.sclass || !def_node.receiver.nil?)
            full.drop_while { |o, _| o == owner }
          end
        when Prism::CallNode
          meth = node.name.to_s
          recv = node.receiver
          if recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)
            klass = Completion.basic_type(recv)
            klass = ScopeResolver.constant(klass, nesting, index).first&.name || klass if klass
            klass && index.method_chain(klass, meth, singleton: true)
          elsif recv
            owner = Completion.receiver_type(recv, document, index)
            owner && index.method_chain(owner, meth)
          elsif !nesting.empty?
            index.method_chain(nesting.join("::"), meth)
          end
        end
      definers = (chain || []).filter_map { |_, e| e }
      return entries if definers.empty?

      (entries.first(1) + definers).uniq { |e| [e.uri.to_s, e.line] }
    end

    def resolve_entries(node, parent, index, nesting = [], document = nil)
      case node
      when Prism::ConstantReadNode, Prism::ConstantWriteNode,
           Prism::ConstantOperatorWriteNode,
           Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        resolve_constant(node.name.to_s, nesting, index)
      when Prism::ConstantPathNode
        index.resolve(Completion.constant_path_name(node))
      when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
           Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode,
           Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::ClassVariableReadNode, Prism::ClassVariableWriteNode,
           Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableTargetNode,
           Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
           Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode,
           Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableTargetNode,
           Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode
        index.resolve(node.name.to_s)
      when Prism::CallNode
        method_entries(node, index, nesting, document)
      when Prism::DefNode
        # Cursor ON a definition's name (go-to-def on `def self.foo`/`def bar`):
        # resolve to that method's own entry, same as hover. The qualified name
        # is owner + sep + name; receiver present => singleton (`.`), else `#`.
        owner = nesting.empty? ? "Object" : nesting.join("::")
        sep = node.receiver ? "." : "#"
        index.definitions("#{owner}#{sep}#{node.name}")
      else
        []
      end
    end

    def resolve_constant(name, nesting, index)
      ScopeResolver.constant(name, nesting, index)
    end

    # Resolve a method call to entries. If the receiver's type is known (literal
    # or constant), anchor to that owner; otherwise fall back to every method of
    # that name across the VM (the user disambiguates).
    def method_entries(node, index, nesting = [], document = nil)
      meth = node.name.to_s

      if node.receiver
        # Explicit receiver: constant -> the class object's singleton methods;
        # instance of known type -> instance methods (ScopeResolver decides).
        found = ScopeResolver.methods_for_receiver(meth, node.receiver, index, document)
        return found if found
      end

      if node.receiver
        # Receiver present but type unknown — cannot scope safely; resolve
        # nothing rather than guess across namespaces.
        return []
      end

      # Bare (receiverless) call: feed the cursor's enclosing class to the VM.
      ScopeResolver.bare_method(meth, nesting, index)
    end

    def location_for(entry)
      return nil unless entry.uri
      # Only real source files are navigable. Synthetic URIs (mruby-core://Class
      # for C builtins with no resolved Ruby/C source) are NOT openable by the
      # editor — returning one makes VS Code try to open it and fail with
      # "Unable to resolve resource". Such entries simply have no go-to-def
      # target (hover still describes them). A real C location, when available,
      # arrives as a file:// uri from CLocator/addr2line and passes this gate.
      return nil unless entry.uri.start_with?("file://")

      # entry.line comes from the VM's source_location as a STRING ("88") and is
      # 1-based. LSP requires an integer, 0-based line. Coerce + shift here; a
      # string line silently makes VS Code reject the location ("no definition
      # found"). nil/blank line anchors to the top of the file.
      # ruby-lsp returns LocationLink[] (verified by driving the real server):
      # { targetUri, targetRange, targetSelectionRange }. targetRange spans the
      # whole definition, targetSelectionRange the name; we store a single
      # 0-based line so both anchor to it. Lines are 0-based integers (the LSP
      # Location contract, distinct from the 1-based hover markdown link).
      raw = entry.line.to_s
      line = raw.match?(/\A\d+\z/) ? [raw.to_i - 1, 0].max : 0
      start_range = {
        start: { line: line, character: 0 },
        end:   { line: line, character: 0 }
      }
      # ruby-lsp's targetSelectionRange is the defined NAME token; fall back to
      # the start line when the harvester didn't capture it (e.g. VM entries).
      sel_range = entry.name_range || start_range
      # Prefer the full def..end span (ruby-lsp's targetRange) when available.
      target_range = entry.range || start_range
      {
        targetUri: entry.uri,
        targetRange: target_range,
        targetSelectionRange: sel_range
      }
    end

    def method_name(qualified) = qualified.split("#", 2).last
  end
end
