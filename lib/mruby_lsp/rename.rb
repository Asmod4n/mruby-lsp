# frozen_string_literal: true

require "prism"
require_relative "locator"
require_relative "document_highlight"

module MrubyLsp
  # textDocument/rename — returns a WorkspaceEdit. Matches ruby-lsp's contract
  # (verified against the running server): ruby-lsp renames CONSTANTS only
  # (classes, modules, constants) and returns null for locals and methods. We do
  # the same: collect every constant occurrence of the target name in the buffer
  # and emit { changes: { uri: [{range, newText}, ...] } }; null otherwise.
  module Rename
    module_function

    CONSTANT_NODES = [
      Prism::ConstantReadNode, Prism::ConstantWriteNode, Prism::ConstantTargetNode,
      Prism::ConstantPathNode, Prism::ConstantPathWriteNode, Prism::ConstantPathTargetNode,
      Prism::ClassNode, Prism::ModuleNode
    ].freeze

    # textDocument/prepareRename — return the renameable identifier's range at
    # the cursor, or null. Like rename, only CONSTANTS are renameable, and only
    # when the cursor is actually ON the constant name (not merely inside an
    # enclosing class/module node), matching ruby-lsp.
    def prepare(document, position)
      root = document.ast.value
      target = Locator.locate(root, document.text, position)&.node
      return nil unless target && constant_like?(target)
      loc = const_name_loc(target)
      return nil unless loc
      r = range_of(loc)
      within?(r, position) ? r : nil
    end

    def within?(r, position)
      line = position[:line]
      char = position[:character]
      return false if line < r[:start][:line] || line > r[:end][:line]
      return false if line == r[:start][:line] && char < r[:start][:character]
      return false if line == r[:end][:line] && char > r[:end][:character]
      true
    end

    def response(document, position, new_name)
      root = document.ast.value
      target = Locator.locate(root, document.text, position)&.node
      return nil unless target
      return nil unless constant_like?(target)

      name = DocumentHighlight.node_value(target)
      return nil unless name

      edits = []
      seen = {}
      DocumentHighlight.walk(root) do |node|
        next unless constant_like?(node)
        next unless DocumentHighlight.node_value(node) == name
        loc = const_name_loc(node)
        next unless loc
        r = range_of(loc)
        key = [r[:start][:line], r[:start][:character], r[:end][:line], r[:end][:character]]
        next if seen[key]
        seen[key] = true
        edits << { range: r, newText: new_name }
      end
      return nil if edits.empty?

      { changes: { document.uri => edits } }
    end

    def constant_like?(node)
      CONSTANT_NODES.any? { |k| node.is_a?(k) }
    end

    # The location of the constant NAME to replace. For class/module nodes that's
    # the constant_path; for plain constant nodes it's the node itself.
    def const_name_loc(node)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        node.constant_path.location
      else
        node.location
      end
    end

    def range_of(loc)
      {
        start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
      }
    end
  end
end
