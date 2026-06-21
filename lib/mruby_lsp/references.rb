# frozen_string_literal: true

require "prism"
require_relative "locator"
require_relative "document_highlight"

module MrubyLsp
  # textDocument/references — every occurrence of the identifier under the cursor,
  # as Location[] (verified against the running server: declaration + call sites,
  # name-token ranges). Honors context.includeDeclaration. Buffer-scoped (our
  # index is the VM; cross-file workspace refs aren't tracked, matching the fact
  # that we don't index arbitrary workspace .rb files).
  #
  # Reuses DocumentHighlight's name extraction + write-node classification; here
  # the WRITE node that is the *declaration* (a def, or a write/target) is
  # included only when includeDeclaration is true.
  module References
    module_function

    def response(document, position, include_declaration)
      root = document.ast.value
      target = Locator.locate(root, document.text, position)&.node
      return [] unless target
      name = DocumentHighlight.node_value(target)
      return [] unless name

      # When excluding declarations, gate by RANGE, not per-node: a class/module
      # definition is two nodes at one range (the ClassNode and its
      # constant_path), so a per-node `declaration?` check would miss the
      # constant_path and still emit the definition.
      decl_keys = include_declaration ? nil : declaration_range_keys(root, name)

      out = []
      seen = {}
      DocumentHighlight.walk(root) do |node|
        next unless DocumentHighlight.node_value(node) == name
        loc = DocumentHighlight.highlight_loc(node)
        next unless loc
        r = Locator.range_of(loc)
        key = [r[:start][:line], r[:start][:character], r[:end][:line], r[:end][:character]]
        next if seen[key]
        seen[key] = true
        next if decl_keys&.key?(key) # declaration excluded
        out << { uri: document.uri, range: r }
      end
      out
    end

    # Name-ranges of every DECLARATION of `name` (class/module name, def name,
    # constant/ivar/cvar/gvar write or target, params).
    def declaration_range_keys(root, name)
      keys = {}
      DocumentHighlight.walk(root) do |node|
        next unless declaration?(node)
        next unless DocumentHighlight.node_value(node) == name
        loc = DocumentHighlight.highlight_loc(node)
        next unless loc
        r = Locator.range_of(loc)
        keys[[r[:start][:line], r[:start][:character], r[:end][:line], r[:end][:character]]] = true
      end
      keys
    end

    # A declaration is the def/class/module node or a write/target (the place the
    # name is introduced), as opposed to a read/call use.
    def declaration?(node)
      node.is_a?(Prism::DefNode) ||
        node.is_a?(Prism::ClassNode) ||
        node.is_a?(Prism::ModuleNode) ||
        node.is_a?(Prism::LocalVariableWriteNode) ||
        node.is_a?(Prism::LocalVariableTargetNode) ||
        node.is_a?(Prism::InstanceVariableWriteNode) ||
        node.is_a?(Prism::ClassVariableWriteNode) ||
        node.is_a?(Prism::GlobalVariableWriteNode) ||
        node.is_a?(Prism::ConstantWriteNode) ||
        node.is_a?(Prism::RequiredParameterNode) ||
        node.is_a?(Prism::OptionalParameterNode)
    end
  end
end
