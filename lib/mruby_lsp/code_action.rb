# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/codeAction — offers refactor actions matching ruby-lsp (verified
  # against the running server): on a non-empty selection, "Refactor: Extract
  # Variable" and "Refactor: Extract Method" (kind refactor.extract); plus
  # "Refactor: Toggle block style" (kind refactor.rewrite) when the selection
  # covers a block. Each is deferred: { title, kind, data:{ range, uri } },
  # resolved by codeAction/resolve. Quickfixes embedded in diagnostics are passed
  # through. Buffer-only.
  module CodeAction
    module_function

    EXTRACT_VARIABLE = "Refactor: Extract Variable"
    EXTRACT_METHOD = "Refactor: Extract Method"
    TOGGLE_BLOCK = "Refactor: Toggle block style"
    REFACTOR_EXTRACT = "refactor.extract"
    REFACTOR_REWRITE = "refactor.rewrite"

    def response(document, range, context, uri)
      actions = []

      # Pass through quickfixes carried on diagnostics (ruby-lsp embeds them in
      # diagnostic.data.code_actions).
      diagnostics = (context && context[:diagnostics]) || []
      diagnostics.each do |d|
        embedded = d.dig(:data, :code_actions)
        actions.concat(embedded) if embedded
      end

      unless empty_range?(range)
        actions << { title: EXTRACT_VARIABLE, kind: REFACTOR_EXTRACT, data: { range: range, uri: uri } }
        actions << { title: EXTRACT_METHOD,   kind: REFACTOR_EXTRACT, data: { range: range, uri: uri } }
        actions << { title: TOGGLE_BLOCK,      kind: REFACTOR_REWRITE, data: { range: range, uri: uri } } if block_in_range?(document, range)
      end

      actions
    end

    def empty_range?(range)
      range[:start] == range[:end]
    end

    # True if a Block or Brace/DoEnd block node overlaps the selection.
    def block_in_range?(document, range)
      root = document.ast.value
      found = false
      walk(root) do |node|
        next unless node.is_a?(Prism::BlockNode)
        loc = node.location
        ns, ne = loc.start_line - 1, loc.end_line - 1
        rs, re = range[:start][:line], range[:end][:line]
        found = true if ns <= re && ne >= rs
      end
      found
    end

    def walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| walk(c, &blk) }
    end
  end
end
