# frozen_string_literal: true

require "prism"

module MrubyLsp
  # Finds the narrowest Prism node covering a cursor position. Pure AST walk —
  # no regex, no text heuristics (per project rule: Ruby is parsed with Prism
  # only). Prism's error-tolerant parser keeps real nodes (ConstantReadNode,
  # CallNode, ConstantPathNode) even for half-typed code, so this works mid-edit.
  module Locator
    module_function

    # Negotiated LSP position encoding: "utf-16" (default) or "utf-8". Set during
    # initialize from the client's general.positionEncodings (ruby-lsp prefers
    # utf-8 when the client offers it). All column<->byte math honors this.
    @encoding = "utf-16"
    class << self
      attr_accessor :encoding
    end

    ENCODINGS = {
      "utf-8" => Encoding::UTF_8, "utf-16" => Encoding::UTF_16LE, "utf-32" => Encoding::UTF_32LE
    }.freeze

    # The negotiated encoding as a Ruby Encoding, for Prism's
    # start/end_code_units_column — so OUTGOING ranges are in LSP code units, not
    # bytes. (INCOMING position math lives in position_to_byte_offset below.)
    def code_units_encoding
      ENCODINGS[encoding] || Encoding::UTF_16LE
    end

    Result = Data.define(:node, :parent, :nesting, :sclass, :def_node)

    # position: { line:, character: } 0-based, character is a UTF-16 code unit.
    def locate(ast_value, source, position)
      offset = position_to_byte_offset(source, position)
      return nil unless offset

      queue = [ast_value]
      closest = ast_value
      parent = nil
      nesting = [] # enclosing class/module names, outermost→innermost
      sclass = false # innermost boundary is `class << self` (implicit self = the singleton)
      def_node = nil # innermost DefNode covering the cursor (BFS visits deeper last)

      until queue.empty?
        candidate = queue.shift
        next unless candidate.is_a?(Prism::Node)

        queue.concat(candidate.compact_child_nodes)

        loc = candidate.location
        start_off = loc.start_offset
        end_off = loc.end_offset
        next unless offset >= start_off && offset <= end_off

        # Prism inserts a zero-ish-width MissingNode where it expected a node but
        # the source is still being typed -- most visibly the last expression
        # before a not-yet-typed `end` at EOF (`class Foo\n def x\n 15.times` ->
        # the `15.times` slot becomes Missing). It would win the narrowest-node
        # race and hand every feature (completion, hover, …) nothing instead of
        # the real node it sits on, so skip it. It has no children to enqueue.
        next if candidate.is_a?(Prism::MissingNode)

        # Track enclosing namespaces that cover the cursor.
        case candidate
        when Prism::ModuleNode, Prism::ClassNode
          nm = constant_path_name(candidate.constant_path)
          nesting << nm if nm
          sclass = false # re-entered an instance context
        when Prism::SingletonClassNode
          # Only `class << self` -- a singleton of an arbitrary expression
          # can't be anchored to a name.
          sclass = true if candidate.expression.is_a?(Prism::SelfNode)
        when Prism::DefNode
          def_node = candidate
        end

        closest_loc = closest.location
        if (end_off - start_off) <= (closest_loc.end_offset - closest_loc.start_offset)
          parent = closest
          closest = candidate
        end
      end

      Result.new(node: closest, parent: parent, nesting: nesting, sclass: sclass, def_node: def_node)
    end

    def constant_path_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = node.respond_to?(:parent) && node.parent ? constant_path_name(node.parent) : nil
        parent ? "#{parent}::#{node.name}" : node.name.to_s
      end
    end

    # LSP position (line, UTF-16 character) -> byte offset into source.
    def position_to_byte_offset(source, position)
      target_line = position[:line]
      target_char = position[:character]

      byte_offset = 0
      current_line = 0

      source.each_line do |line|
        if current_line == target_line
          return byte_offset + utf16_units_to_bytes(line, target_char)
        end
        byte_offset += line.bytesize
        current_line += 1
      end

      # Cursor on the trailing (possibly empty) line.
      return byte_offset if current_line == target_line

      nil
    end

    # Within one line, convert an LSP character column to a byte offset, honoring
    # the negotiated position encoding (utf-16 default; utf-8 when negotiated).
    def utf16_units_to_bytes(line, units)
      if Locator.encoding == "utf-8"
        return [units, line.bytesize].min
      end
      return line.bytesize if units >= line.encode("UTF-16LE").bytesize / 2

      utf16 = line.encode("UTF-16LE")
      prefix = utf16.bytes.first(units * 2).pack("C*").force_encoding("UTF-16LE")
      prefix.encode("UTF-8").bytesize
    end

    # A Prism location -> an LSP Range: 0-based lines, columns in the negotiated
    # position encoding (code units). The one converter every range-emitting
    # feature (documentHighlight, references, rename, document/workspace symbols,
    # type hierarchy, selection range) shares, so they cannot disagree on how a
    # source span maps to LSP coordinates.
    def range_of(loc)
      {
        start: { line: loc.start_line - 1, character: loc.start_code_units_column(code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(code_units_encoding) }
      }
    end
  end
end
