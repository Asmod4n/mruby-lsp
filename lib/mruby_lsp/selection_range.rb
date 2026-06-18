# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/selectionRange — replicates ruby-lsp's SelectionRanges request
  # (verified against the running server). Builds a SelectionRange {range, parent}
  # for EVERY node (using child_nodes, parent-linked), ordered deepest-first via
  # unshift; then for each requested position returns the first range that covers
  # it. Buffer-only. Output: per position, nested { range, parent:{range,parent}}.
  module SelectionRange
    module_function

    def response(document, positions)
      ranges = build(document.ast.value)
      positions.map do |pos|
        ranges.find { |r| cover?(r[:range], pos) }
      end
    end

    # Mirror ruby-lsp: queue starts at root; for each node, make a range linked to
    # its parent, prepend children to the queue, and unshift the range so the
    # final array is deepest-first. We use child_nodes (NOT compact) to match
    # ruby-lsp's node set (nils are skipped by the `next unless node` guard).
    def build(root)
      ranges = []
      queue = [[root, nil]]
      until queue.empty?
        node, parent = queue.shift
        next unless node
        range = { range: range_of(node.location) }
        range[:parent] = parent if parent # outermost has NO parent key
        children = node.child_nodes.map { |c| [c, range] }
        queue.unshift(*children)
        ranges.unshift(range)
      end
      ranges
    end

    def range_of(loc)
      {
        start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
      }
    end

    # position covered by [start, end) inclusive of start, ruby-lsp uses
    # start <= pos <= end on (line, character).
    def cover?(range, pos)
      s = range[:start]; e = range[:end]
      after_start = pos[:line] > s[:line] || (pos[:line] == s[:line] && pos[:character] >= s[:character])
      before_end  = pos[:line] < e[:line] || (pos[:line] == e[:line] && pos[:character] <= e[:character])
      after_start && before_end
    end
  end
end
