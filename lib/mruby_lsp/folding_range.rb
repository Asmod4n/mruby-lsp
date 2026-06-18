# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/foldingRange — faithful port of ruby-lsp's FoldingRanges listener
  # (verified against its own expectation suite). Emitted in document order; we do
  # NOT sort (ruby-lsp emits in dispatch order and so do we).
  #
  # Three range kinds:
  #   region  — structural nodes; if/in/rescue/when fold to the LAST statement's
  #             end line (add_statements_range), others to end_line-1 (simple).
  #   comment — runs of >=2 consecutive non-trailing line comments.
  #   imports — runs of >=2 consecutive require/require_relative calls.
  #
  # add_lines_range emits any pending require-run first, then the region (1-based
  # -> 0-based, skipped when start >= end).
  module FoldingRange
    module_function

    STATEMENTS_NODES = [
      Prism::IfNode, Prism::InNode, Prism::RescueNode, Prism::WhenNode
    ].freeze

    SIMPLE_NODES = [
      Prism::ArrayNode, Prism::BlockNode, Prism::CaseNode, Prism::CaseMatchNode,
      Prism::ClassNode, Prism::ModuleNode, Prism::ForNode, Prism::HashNode,
      Prism::SingletonClassNode, Prism::UnlessNode, Prism::UntilNode,
      Prism::WhileNode, Prism::ElseNode, Prism::EnsureNode, Prism::BeginNode,
      Prism::LambdaNode
    ].freeze

    def response(document)
      result = document.ast
      state = { out: [], requires: [] }
      walk(result.value, state)
      emit_requires(state) # flush trailing require run
      push_comments(result.comments, state[:out])
      state[:out]
    end

    def walk(node, state)
      return unless node.is_a?(Prism::Node)
      visit(node, state)
      node.compact_child_nodes.each { |c| walk(c, state) }
    end

    def visit(node, state)
      case node
      when *STATEMENTS_NODES
        add_statements_range(node, state)
      when Prism::InterpolatedStringNode
        opening = node.opening_loc || node.location
        closing = node.closing_loc || node.parts.last&.location || node.location
        add_lines_range(opening.start_line, closing.start_line - 1, state)
      when Prism::DefNode
        params = node.parameters
        ploc = params&.location
        loc = node.location
        if params && ploc.end_line > loc.start_line
          add_lines_range(loc.start_line, ploc.end_line, state)
          add_lines_range(ploc.end_line + 1, loc.end_line - 1, state)
        else
          add_lines_range(loc.start_line, loc.end_line - 1, state)
        end
      when Prism::CallNode
        if require?(node)
          state[:requires] << node
          return
        end
        loc = node.location
        add_lines_range(loc.start_line, loc.end_line - 1, state)
      when *SIMPLE_NODES
        loc = node.location
        add_lines_range(loc.start_line, loc.end_line - 1, state)
      end
    end

    # if/in/rescue/when: fold to the end line of the LAST statement in the body.
    def add_statements_range(node, state)
      statements = node.statements
      return unless statements
      last = statements.body.last
      return unless last
      add_lines_range(node.location.start_line, last.location.end_line, state)
    end

    def add_lines_range(start_line, end_line, state)
      emit_requires(state)
      return if start_line >= end_line
      state[:out] << { startLine: start_line - 1, endLine: end_line - 1, kind: "region" }
    end

    def emit_requires(state)
      reqs = state[:requires]
      if reqs.length > 1
        state[:out] << {
          startLine: reqs.first.location.start_line - 1,
          endLine: reqs.last.location.end_line - 1,
          kind: "imports"
        }
      end
      reqs.clear
    end

    def require?(node)
      msg = node.message
      return false unless msg == "require" || msg == "require_relative"
      recv = node.receiver
      return false unless recv.nil? || recv.slice == "Kernel"
      args = node.arguments&.arguments
      return false unless args
      args.length == 1 && args.first.is_a?(Prism::StringNode)
    end

    # Runs of >=2 consecutive non-trailing line comments -> one comment fold.
    def push_comments(comments, out)
      return unless comments
      chunk = []
      flush = lambda do
        if chunk.length > 1
          out << {
            startLine: chunk.first.location.start_line - 1,
            endLine: chunk.last.location.end_line - 1,
            kind: "comment"
          }
        end
        chunk = []
      end
      comments.each do |c|
        if chunk.empty?
          chunk = [c] unless trailing?(c)
          next
        end
        prev = chunk.last
        if prev.location.end_line + 1 == c.location.start_line && !trailing?(prev) && !trailing?(c)
          chunk << c
        else
          flush.call
          chunk = trailing?(c) ? [] : [c]
        end
      end
      flush.call
    end

    def trailing?(comment)
      comment.respond_to?(:trailing?) ? comment.trailing? : false
    end
  end
end
