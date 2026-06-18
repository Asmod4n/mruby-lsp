# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/inlayHint — replicates ruby-lsp's InlayHints listener:
  #   - implicitRescue: a bare `rescue` gets a "StandardError" hint after the kw.
  #   - implicitHashValue: shorthand `{ x: }` / `foo(x:)` gets the implied value
  #     name + ruby-lsp's per-kind tooltip (local variable / constant / method).
  # Both kinds are pure Prism AST (no VM) and apply to mruby unchanged; output is
  # byte-identical to ruby-lsp. ruby-lsp ships them opt-in (off); we default ON
  # since both apply cleanly and there is no settings surface yet to opt in
  # through. The config flags remain so a client toggle can drive them later.
  module InlayHint
    module_function

    RESCUE_LEN = "rescue".length

    def config
      @config ||= { implicitRescue: true, implicitHashValue: true }
    end

    def response(document, range)
      cfg = config
      return [] unless cfg[:implicitRescue] || cfg[:implicitHashValue]

      hints = []
      walk(document.ast.value) do |node|
        if cfg[:implicitRescue] && node.is_a?(Prism::RescueNode) && node.exceptions.empty?
          loc = node.location
          hints << {
            position: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) + RESCUE_LEN },
            label: "StandardError",
            paddingLeft: true,
            tooltip: "StandardError is implied in a bare rescue"
          }
        end
        if cfg[:implicitHashValue] && node.is_a?(Prism::ImplicitNode)
          name, tooltip = implicit_value(node)
          next if name.empty?
          loc = node.location
          hints << {
            position: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) + name.length + 1 },
            label: name,
            paddingLeft: true,
            tooltip: tooltip
          }
        end
      end
      within(hints, range)
    end

    # The omitted hash value's name + ruby-lsp's exact tooltip per node kind.
    def implicit_value(node)
      v = node.value
      case v
      when Prism::CallNode
        n = v.name.to_s
        [n, "This is a method call. Method name: #{n}"]
      when Prism::ConstantReadNode
        n = v.name.to_s
        [n, "This is a constant: #{n}"]
      when Prism::LocalVariableReadNode
        n = v.name.to_s
        [n, "This is a local variable: #{n}"]
      else
        ["", ""]
      end
    end

    def within(hints, range)
      return hints unless range
      rs = range[:start][:line]; re = range[:end][:line]
      hints.select { |h| h[:position][:line].between?(rs, re) }
    end

    def walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| walk(c, &blk) }
    end
  end
end
