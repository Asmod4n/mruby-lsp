# frozen_string_literal: true

require "prism"
require_relative "code_action_resolve"

module MrubyLsp
  # textDocument/codeAction — offers the refactor actions ruby-lsp offers
  # (0.26.9, the pinned vendored-vector commit): on a non-empty selection
  # "Refactor: Extract Variable" / "Refactor: Extract Method"
  # (refactor.extract); "Refactor: Toggle block style" (refactor.rewrite) on
  # any non-empty selection, or at a cursor inside a block; and the Create
  # Attribute Reader/Writer/Accessor family when an instance variable is under
  # the cursor/selection. Each offer is deferred: { title, kind, data:{ range,
  # uri } }, resolved into a WorkspaceEdit by codeAction/resolve
  # (code_action_resolve.rb). Quickfixes embedded in diagnostics are passed
  # through. Buffer-only.
  module CodeAction
    module_function

    EXTRACT_VARIABLE = "Refactor: Extract Variable"
    EXTRACT_METHOD = "Refactor: Extract Method"
    TOGGLE_BLOCK = "Refactor: Toggle block style"
    CREATE_ATTR_READER = "Create Attribute Reader"
    CREATE_ATTR_WRITER = "Create Attribute Writer"
    CREATE_ATTR_ACCESSOR = "Create Attribute Accessor"
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
      end
      actions.concat(toggle_block_style_action(document, range, uri))
      actions.concat(attribute_actions(document, range, uri))

      actions
    end

    def empty_range?(range)
      range[:start] == range[:end]
    end

    # Offered at a cursor only when it sits inside a block; on a non-empty
    # selection it is always offered (resolve decides applicability) — exactly
    # ruby-lsp's rule.
    def toggle_block_style_action(document, range, uri)
      if empty_range?(range)
        node = CodeActionResolve.locate_path(
          document.ast.value,
          CodeActionResolve.offset_of(document, range[:start]),
          [Prism::BlockNode],
        ).first
        return [] unless node.is_a?(Prism::BlockNode)
      end

      [{ title: TOGGLE_BLOCK, kind: REFACTOR_REWRITE, data: { range: range, uri: uri } }]
    end

    # Offered when an instance variable is under the cursor (empty range) or
    # inside the selection.
    def attribute_actions(document, range, uri)
      root = document.ast.value
      node = CodeActionResolve.first_within(root, CodeActionResolve.byte_span(document, range), CodeActionResolve::IVAR_NODES) unless empty_range?(range)

      if node.nil?
        node = CodeActionResolve.locate_path(
          root,
          CodeActionResolve.offset_of(document, range[:start]),
          CodeActionResolve::IVAR_NODES,
        ).first
        return [] unless CodeActionResolve::IVAR_NODES.include?(node.class)
      end

      [
        { title: CREATE_ATTR_READER,   kind: "", data: { range: range, uri: uri } },
        { title: CREATE_ATTR_WRITER,   kind: "", data: { range: range, uri: uri } },
        { title: CREATE_ATTR_ACCESSOR, kind: "", data: { range: range, uri: uri } },
      ]
    end
  end
end
