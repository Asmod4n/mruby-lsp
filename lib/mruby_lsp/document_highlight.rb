# frozen_string_literal: true

require "prism"
require_relative "locator"

module MrubyLsp
  # textDocument/documentHighlight — matches ruby-lsp's listener (verified
  # against its own expectation suite). Two modes, mirroring ruby-lsp:
  #
  #  1. Identifier target (var / const / call): highlight every node whose
  #     node_value equals the target AND whose node-category matches the target's
  #     category (a constant target only matches constant nodes, a local only
  #     locals, etc.). READ(2) vs WRITE(3) by node type.
  #
  #  2. Structural target (class/module/def/case/while/until/for/if/unless/
  #     begin): highlight the KEYWORD PAIR (e.g. `class`/`end`) as TEXT(1), only
  #     for the structure whose keyword/end covers the cursor.
  #
  # Output is in document (traversal) order — we never sort, matching ruby-lsp
  # which emits in dispatch order.
  module DocumentHighlight
    module_function

    READ = 2
    WRITE = 3
    TEXT = 1

    GLOBAL = %i[
      GlobalVariableAndWriteNode GlobalVariableOperatorWriteNode
      GlobalVariableOrWriteNode GlobalVariableReadNode
      GlobalVariableTargetNode GlobalVariableWriteNode
    ].freeze
    IVAR = %i[
      InstanceVariableAndWriteNode InstanceVariableOperatorWriteNode
      InstanceVariableOrWriteNode InstanceVariableReadNode
      InstanceVariableTargetNode InstanceVariableWriteNode
    ].freeze
    CVAR = %i[
      ClassVariableAndWriteNode ClassVariableOperatorWriteNode
      ClassVariableOrWriteNode ClassVariableReadNode
      ClassVariableTargetNode ClassVariableWriteNode
    ].freeze
    CONST = %i[
      ConstantAndWriteNode ConstantOperatorWriteNode ConstantOrWriteNode
      ConstantReadNode ConstantTargetNode ConstantWriteNode
    ].freeze
    CONST_PATH = %i[
      ConstantPathAndWriteNode ConstantPathNode ConstantPathOperatorWriteNode
      ConstantPathOrWriteNode ConstantPathTargetNode ConstantPathWriteNode
    ].freeze
    LOCAL = %i[
      LocalVariableAndWriteNode LocalVariableOperatorWriteNode
      LocalVariableOrWriteNode LocalVariableReadNode LocalVariableTargetNode
      LocalVariableWriteNode BlockParameterNode RequiredParameterNode
      RequiredKeywordParameterNode OptionalKeywordParameterNode
      RestParameterNode OptionalParameterNode KeywordRestParameterNode
    ].freeze

    STRUCTURAL = {
      ClassNode:     %i[class_keyword_loc end_keyword_loc],
      ModuleNode:    %i[module_keyword_loc end_keyword_loc],
      DefNode:       %i[def_keyword_loc end_keyword_loc],
      CaseNode:      %i[case_keyword_loc end_keyword_loc],
      WhileNode:     %i[keyword_loc closing_loc],
      UntilNode:     %i[keyword_loc closing_loc],
      ForNode:       %i[for_keyword_loc end_keyword_loc],
      IfNode:        %i[if_keyword_loc end_keyword_loc],
      UnlessNode:    %i[keyword_loc end_keyword_loc],
      BeginNode:     %i[begin_keyword_loc end_keyword_loc],
      BlockNode:     %i[opening_loc closing_loc],
      LambdaNode:    %i[opening_loc closing_loc]
    }.freeze

    def response(document, position)
      root = document.ast.value
      target = Locator.locate(root, document.text, position)&.node
      return [] unless target

      # DefNode is hybrid: it matches its name against calls+defs (identifier)
      # AND highlights its def/end keyword pair when the cursor is on a keyword.
      if target.is_a?(Prism::DefNode)
        out = identifier_highlights(root, target.name.to_s, %i[CallNode DefNode])
        out.concat(structural_highlights(root, target, position))
        return dedupe(out)
      end

      if structural?(target)
        structural_highlights(root, target, position)
      else
        value = node_value(target)
        return [] unless value
        identifier_highlights(root, value, categories_for(target))
      end
    end

    # Remove exact-duplicate highlights while preserving document order.
    def dedupe(arr)
      seen = {}
      arr.reject { |h| k = h.to_s; dup = seen[k]; seen[k] = true; dup }
    end

    def structural?(node)
      STRUCTURAL.key?(short_class(node))
    end

    def structural_highlights(root, target, position)
      target_sym = short_class(target)
      kw_m, end_m = STRUCTURAL.fetch(target_sym)
      out = []
      walk(root) do |node|
        next unless short_class(node) == target_sym
        kw = node.respond_to?(kw_m) ? node.public_send(kw_m) : nil
        en = node.respond_to?(end_m) ? node.public_send(end_m) : nil
        next unless kw && en && en.length.positive?
        next unless covers?(kw, position) || covers?(en, position)
        out << { range: range_of(kw), kind: TEXT }
        out << { range: range_of(en), kind: TEXT }
      end
      out
    end

    def identifier_highlights(root, value, cats)
      out = []
      walk(root) do |node|
        sym = short_class(node)
        next unless cats.include?(sym)
        next unless node_value(node) == value
        loc = highlight_loc(node)
        next unless loc
        out << { range: range_of(loc), kind: write?(node) ? WRITE : READ }
      end
      out
    end

    def categories_for(node)
      sym = short_class(node)
      return GLOBAL if GLOBAL.include?(sym)
      return IVAR if IVAR.include?(sym)
      return CVAR if CVAR.include?(sym)
      if CONST.include?(sym) || CONST_PATH.include?(sym) || %i[ClassNode ModuleNode].include?(sym)
        return CONST + CONST_PATH + %i[ClassNode ModuleNode]
      end
      return LOCAL if LOCAL.include?(sym)
      return %i[CallNode DefNode] if sym == :CallNode
      []
    end

    def node_value(node)
      case node
      when Prism::ConstantPathNode, Prism::ConstantPathTargetNode,
           Prism::ConstantPathWriteNode, Prism::ConstantPathOperatorWriteNode,
           Prism::ConstantPathAndWriteNode, Prism::ConstantPathOrWriteNode
        node.slice
      when Prism::CallNode
        node.message
      when Prism::ClassNode, Prism::ModuleNode
        node.constant_path.slice
      else
        node.respond_to?(:name) ? node.name.to_s : nil
      end
    end

    WRITE_SUFFIX = /(?:WriteNode|TargetNode)\z/

    def write?(node)
      return true if node.is_a?(Prism::DefNode)
      return true if param_node?(node)
      return true if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      WRITE_SUFFIX.match?(short_class(node).to_s)
    end

    def param_node?(node)
      node.is_a?(Prism::RequiredParameterNode) || node.is_a?(Prism::OptionalParameterNode) ||
        node.is_a?(Prism::RestParameterNode) || node.is_a?(Prism::KeywordRestParameterNode) ||
        node.is_a?(Prism::BlockParameterNode) || node.is_a?(Prism::RequiredKeywordParameterNode) ||
        node.is_a?(Prism::OptionalKeywordParameterNode)
    end

    def highlight_loc(node)
      if node.is_a?(Prism::DefNode)
        node.name_loc
      elsif node.is_a?(Prism::CallNode)
        node.message_loc || node.location
      elsif node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        node.constant_path.location
      elsif node.respond_to?(:name_loc) && node.name_loc
        node.name_loc
      else
        node.location
      end
    end

    def walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| walk(c, &blk) }
    end

    def short_class(node)
      node.class.name.split("::").last.to_sym
    end

    def covers?(loc, position)
      line = position[:line]; col = position[:character]
      sl = loc.start_line - 1; el = loc.end_line - 1
      return false if line < sl || line > el
      return false if line == sl && col < loc.start_code_units_column(Locator.code_units_encoding)
      return false if line == el && col > loc.end_code_units_column(Locator.code_units_encoding)
      true
    end

    def range_of(loc)
      {
        start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
      }
    end
  end
end
