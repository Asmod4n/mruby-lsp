# frozen_string_literal: true

require "prism"
require_relative "locator"

module MrubyLsp
  # Debug-hover support. When a debug session is live and you hover the source,
  # VS Code asks for the EXPRESSION to evaluate at that position. With no
  # provider it falls back to a word-pattern heuristic that has no language
  # knowledge — hovering inside "hello world" yields the fragment `"hello`, which
  # mrdb then chokes on (unterminated string). We answer with the RANGE + TEXT of
  # the real expression under the cursor, found with Prism (never regex).
  #
  # Contract (what every cursor position maps to):
  #   - inside a delimited literal ("…", '…', :sym, /re/, %q/%w…): the WHOLE
  #     literal, from any interior char including the quotes and the `#{}` of an
  #     interpolation;
  #   - on an interpolated value (`line` in "x#{line}"): just that inner value,
  #     so you can inspect it;
  #   - on a variable / constant / ivar / cvar / gvar read: that name;
  #   - on the NAME of an assignment target (`a` in `a = 1`): the name alone
  #     (never the whole `a = 1`, which would re-assign on evaluate);
  #   - on a literal (number, symbol, array, hash, range): the literal;
  #   - on an argument-less call (attribute read like `conn.size`): the call;
  #   - on a call WITH arguments (`puts "x"`, `conn.write(x)`) or anywhere with
  #     no evaluable expression (operators, whitespace, keywords): nil — VS Code
  #     then shows nothing rather than something broken.
  module Evaluatable
    module_function

    # -> { range:, expression: } for the expression at `position`, or nil.
    def response(document, position)
      offset = Locator.position_to_byte_offset(document.text, position)
      return nil unless offset

      chain = covering_chain(document.ast.value, offset)
      return nil if chain.empty?

      loc = evaluable_location(chain, offset)
      return nil unless loc

      { range: loc_range(loc), expression: loc.slice }
    end

    # Root-excluded path of Prism nodes covering `offset`, outermost → innermost.
    # Pure AST descent: at each level take the first child node that covers the
    # offset and recurse. No text scanning.
    def covering_chain(ast_value, offset)
      chain = []
      node = ast_value
      while node.is_a?(Prism::Node)
        child = node.compact_child_nodes.find do |c|
          c.is_a?(Prism::Node) && offset >= c.location.start_offset && offset <= c.location.end_offset
        end
        break unless child
        chain << child
        node = child
      end
      chain
    end

    # Decide the location to evaluate from the covering chain.
    def evaluable_location(chain, offset)
      inner = chain[-1]
      parent = chain[-2]

      # Deepest delimited literal enclosing the cursor (its own quotes/regexp
      # slashes/%-delimiters), if any.
      str = nil
      chain.each { |n| str = n if delimited_literal?(n) }

      if str
        # Inside a string-ish literal. If the cursor sits on a genuine value
        # nested via interpolation (`#{ value }`), let them inspect THAT; the
        # `#{}` and literal segments and quotes all fall back to the whole
        # literal.
        if inner.equal?(str)
          return str.location
        elsif clean_value?(inner, parent)
          return value_location(inner, parent, offset)
        else
          return str.location
        end
      end

      value_location(inner, parent, offset)
    end

    # A node whose source slice is, on its own, a complete, side-effect-light
    # expression worth showing. Used to pick interpolated values out of strings
    # and (via value_location) to resolve the plain case.
    def clean_value?(node, parent)
      case node
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode,
           Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode,
           Prism::ConstantReadNode, Prism::ConstantPathNode,
           Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode,
           Prism::ImaginaryNode, Prism::TrueNode, Prism::FalseNode,
           Prism::NilNode, Prism::ArrayNode, Prism::HashNode, Prism::RangeNode
        true
      when Prism::CallNode
        # Argument-less calls are treated as attribute reads (conn.size); a call
        # WITH arguments or a block is a statement we must not re-run.
        node.arguments.nil? && node.block.nil?
      else
        delimited_literal?(node, parent)
      end
    end

    # The location to hand back for a resolved node (gating assignment targets to
    # their NAME so we never echo `a = 1`), or nil if the node is not evaluable.
    def value_location(node, parent, offset)
      case node
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode,
           Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode,
           Prism::ConstantReadNode, Prism::ConstantPathNode,
           Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode,
           Prism::ImaginaryNode, Prism::TrueNode, Prism::FalseNode,
           Prism::NilNode, Prism::ArrayNode, Prism::HashNode, Prism::RangeNode
        node.location
      when Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode,
           Prism::InstanceVariableWriteNode, Prism::InstanceVariableTargetNode,
           Prism::ClassVariableWriteNode, Prism::ClassVariableTargetNode,
           Prism::GlobalVariableWriteNode, Prism::GlobalVariableTargetNode,
           Prism::ConstantWriteNode, Prism::ConstantTargetNode
        nl = node.respond_to?(:name_loc) ? node.name_loc : nil
        return node.location unless nl
        within?(nl, offset) ? nl : nil
      when Prism::CallNode
        return nil unless node.arguments.nil? && node.block.nil?
        node.location
      else
        delimited_literal?(node, parent) ? node.location : nil
      end
    end

    # A literal carrying its own delimiters, so its slice stands alone. The
    # interpolated/regexp/xstring nodes always do; a String/Symbol node does only
    # when its slice opens with a quote/sigil (segment parts inside an
    # interpolation and %w/%i array elements have none).
    def delimited_literal?(node, _parent = nil)
      case node
      when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode,
           Prism::InterpolatedXStringNode, Prism::XStringNode,
           Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
        true
      when Prism::StringNode, Prism::SymbolNode
        s = node.slice
        return false if s.empty?
        c = s[0]
        c == '"' || c == "'" || c == "`" || c == ":" || c == "%" || c == "/"
      else
        false
      end
    end

    def within?(loc, offset)
      offset >= loc.start_offset && offset <= loc.end_offset
    end

    # Prism location -> LSP range, in the negotiated position encoding (matches
    # buffer_harvester#loc_range).
    def loc_range(loc)
      enc = Locator.code_units_encoding
      { start: { line: loc.start_line - 1, character: loc.start_code_units_column(enc) },
        end:   { line: loc.end_line - 1,   character: loc.end_code_units_column(enc) } }
    end
  end
end
