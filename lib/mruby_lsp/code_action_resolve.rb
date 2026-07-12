# frozen_string_literal: true

require "prism"
require_relative "locator"

module MrubyLsp
  # codeAction/resolve — turns the edit-less refactor actions offered by
  # CodeAction into WorkspaceEdits. A faithful port of ruby-lsp 0.26.9's
  # CodeActionResolve (the pinned vendored-vector commit), on our Document/
  # Locator plumbing: Extract Variable, Extract Method, Toggle block style,
  # and the Create Attribute Reader/Writer/Accessor family. Buffer-only, no
  # VM involved. On any unresolvable input the ORIGINAL action is returned
  # unchanged (no edit -> the client no-ops) — degrade, don't crash.
  module CodeActionResolve
    module_function

    NEW_VARIABLE_NAME = "new_variable"
    NEW_METHOD_NAME = "new_method"

    IVAR_NODES = [
      Prism::InstanceVariableAndWriteNode,
      Prism::InstanceVariableOperatorWriteNode,
      Prism::InstanceVariableOrWriteNode,
      Prism::InstanceVariableReadNode,
      Prism::InstanceVariableTargetNode,
      Prism::InstanceVariableWriteNode,
    ].freeze

    # Raised internally for any input we cannot resolve into an edit.
    class Unresolvable < StandardError; end

    def response(document, action)
      return action if document.nil? || document.text.empty?

      title = action[:title].to_s
      edit =
        case title
        when CodeAction::EXTRACT_VARIABLE then refactor_variable(document, action)
        when CodeAction::EXTRACT_METHOD   then refactor_method(document, action)
        when CodeAction::TOGGLE_BLOCK     then switch_block_style(document, action)
        when CodeAction::CREATE_ATTR_READER, CodeAction::CREATE_ATTR_WRITER, CodeAction::CREATE_ATTR_ACCESSOR
          create_attribute_accessor(document, action)
        end
      return action unless edit

      { title: title, edit: edit }
    rescue Unresolvable
      action
    end

    # ── the three refactors ──────────────────────────────────────────────────

    def switch_block_style(document, action)
      source_range = action.dig(:data, :range)
      root = document.ast.value

      if source_range[:start] == source_range[:end]
        node = locate_path(root, offset_of(document, source_range[:start]), [Prism::BlockNode]).first
        raise Unresolvable unless node.is_a?(Prism::BlockNode)

        # The call whose block the cursor is inside of: the deepest call at the
        # block's own start offset that owns exactly this block.
        target = locate_path(root, node.location.start_offset, [Prism::CallNode]).first
        raise Unresolvable unless target.is_a?(Prism::CallNode) && target.block == node
      else
        target = first_within(root, byte_span(document, source_range), [Prism::CallNode])
        raise Unresolvable unless target.is_a?(Prism::CallNode)

        node = target.block
        raise Unresolvable unless node.is_a?(Prism::BlockNode)
      end

      indentation = (" " * target.location.start_column unless node.opening_loc.slice == "do")
      workspace_edit(action, [
        { range: Locator.range_of(node.location), newText: switch_block_recursive(document, node, indentation) },
      ])
    end

    def refactor_variable(document, action)
      source_range = action.dig(:data, :range)
      raise Unresolvable if source_range[:start] == source_range[:end]

      start_index, end_index = byte_span(document, source_range)
      extracted_source = document.text.byteslice(start_index, end_index - start_index)
      root = document.ast.value

      # The closest statement list, so the extraction lands in a valid spot.
      closest_statements, parent_statements =
        locate_path(root, start_index, [Prism::StatementsNode, Prism::BlockNode])
      raise Unresolvable if closest_statements.nil? || closest_statements.child_nodes.compact.empty?

      # The child with the end line closest ABOVE the selection; the extraction
      # goes right around it.
      closest_node = closest_statements.child_nodes.compact.min_by do |node|
        distance = source_range.dig(:start, :line) - (node.location.end_line - 1)
        distance <= 0 ? Float::INFINITY : distance
      end
      raise Unresolvable if closest_node.is_a?(Prism::MissingNode)

      closest_node_loc = closest_node.location
      if parent_statements.is_a?(Prism::BlockNode) &&
         parent_statements.location.start_line == parent_statements.location.end_line
        # One-line block: extract INSIDE it, semicolon-separated.
        variable_source = " #{NEW_VARIABLE_NAME} = #{extracted_source};"
        character = source_range.dig(:start, :character) - 1
        target_range = {
          start: { line: closest_node_loc.end_line - 1, character: character },
          end: { line: closest_node_loc.end_line - 1, character: character },
        }
      else
        # Selection nested inside the closest node -> place the extraction at
        # its start line; otherwise right below it.
        if closest_node_loc.start_line - 1 <= source_range.dig(:start, :line) &&
           closest_node_loc.end_line - 1 >= source_range.dig(:end, :line)
          indentation_line_number = closest_node_loc.start_line - 1
          target_line = indentation_line_number
        else
          target_line = closest_node_loc.end_line
          indentation_line_number = closest_node_loc.end_line - 1
        end

        lines = document.text.lines
        indentation_line = lines[indentation_line_number]
        raise Unresolvable unless indentation_line
        indentation = leading_spaces(indentation_line)

        target_range = {
          start: { line: target_line, character: indentation },
          end: { line: target_line, character: indentation },
        }

        line = lines[target_line]
        raise Unresolvable unless line
        variable_source =
          if line.strip.empty?
            "\n#{" " * indentation}#{NEW_VARIABLE_NAME} = #{extracted_source}"
          else
            "#{NEW_VARIABLE_NAME} = #{extracted_source}\n#{" " * indentation}"
          end
      end

      workspace_edit(action, [
        { range: source_range, newText: NEW_VARIABLE_NAME },
        { range: target_range, newText: variable_source },
      ])
    end

    def refactor_method(document, action)
      source_range = action.dig(:data, :range)
      raise Unresolvable if source_range[:start] == source_range[:end]

      start_index, end_index = byte_span(document, source_range)
      extracted_source = document.text.byteslice(start_index, end_index - start_index)

      # The closest surrounding method: the new def goes right after it. At
      # script level (no def), it goes right above the selection instead.
      closest_node = locate_path(document.ast.value, start_index, [Prism::DefNode]).first

      if closest_node.is_a?(Prism::DefNode)
        end_keyword_loc = closest_node.end_keyword_loc
        raise Unresolvable unless end_keyword_loc

        end_line = end_keyword_loc.end_line - 1
        character = end_keyword_loc.end_column
        indentation = " " * end_keyword_loc.start_column
        new_method_source = "\n\n#{indentation}def #{NEW_METHOD_NAME}\n#{indentation}  #{extracted_source}\n#{indentation}end"
        target_range = {
          start: { line: end_line, character: character },
          end: { line: end_line, character: character },
        }
      else
        new_method_source = "def #{NEW_METHOD_NAME}\n  #{extracted_source.gsub("\n", "\n  ")}\nend\n\n"
        line = [0, source_range.dig(:start, :line) - 1].max
        target_range = {
          start: { line: line, character: source_range.dig(:start, :character) },
          end: { line: line, character: source_range.dig(:start, :character) },
        }
      end

      workspace_edit(action, [
        { range: target_range, newText: new_method_source },
        { range: source_range, newText: NEW_METHOD_NAME },
      ])
    end

    # ── Create Attribute Reader/Writer/Accessor ─────────────────────────────

    def create_attribute_accessor(document, action)
      source_range = action.dig(:data, :range)
      root = document.ast.value

      node = first_within(root, byte_span(document, source_range), IVAR_NODES) if source_range[:start] != source_range[:end]
      node ||= locate_path(root, offset_of(document, source_range[:start]), IVAR_NODES).first
      raise Unresolvable unless IVAR_NODES.include?(node.class)

      # ruby-lsp resolves the surrounding class/module from the ivar's
      # (1-based) start line fed into the (0-based) locator — i.e. one line
      # below the ivar — and inserts at the class node's start_line, which by
      # the same off-by-one lands on the first body line. Mirrored as-is:
      # byte-compatibility with the vendored vectors beats prettiness.
      anchor = offset_of(document, { line: node.location.start_line, character: node.location.start_character_column })
      raise Unresolvable unless anchor
      closest_node = locate_path(root, anchor, [Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode]).first
      raise Unresolvable unless closest_node

      attribute_name = node.name[1..]
      indentation = " " * (closest_node.location.start_column + 2)
      verb =
        case action[:title]
        when CodeAction::CREATE_ATTR_READER then "attr_reader"
        when CodeAction::CREATE_ATTR_WRITER then "attr_writer"
        else "attr_accessor"
        end

      target_start_line = closest_node.location.start_line
      workspace_edit(action, [
        {
          range: {
            start: { line: target_start_line, character: 0 },
            end: { line: target_start_line, character: 0 },
          },
          newText: "#{indentation}#{verb} :#{attribute_name}\n\n",
        },
      ])
    end

    # ── block style rewriting (shared with the toggle refactor) ─────────────

    # do/end <-> braces, recursing into the FIRST nested block like ruby-lsp:
    # newlines become semicolons when flattening to braces, semicolons become
    # newlines when expanding to do/end.
    def switch_block_recursive(document, node, indentation)
      parameters = node.parameters
      body = node.body

      source = +""
      if indentation
        source << "do"
        source << " #{parameters.slice}" if parameters
        source << "\n#{indentation}  "
        source << switch_block_body(document, body, indentation) if body
        source << "\n#{indentation}end"
      else
        source << "{ "
        source << "#{parameters.slice} " if parameters
        source << switch_block_body(document, body, nil) if body
        source << "}"
      end
      source
    end

    def switch_block_body(document, body, indentation)
      body_loc = body.location
      nested_block = first_within(document.ast.value, [body_loc.start_offset, body_loc.end_offset], [Prism::BlockNode])

      body_content = body.slice.dup
      if nested_block.is_a?(Prism::BlockNode)
        location = nested_block.location
        correction_start = location.start_offset - body_loc.start_offset
        correction_end = location.end_offset - body_loc.start_offset
        next_indentation = indentation ? "#{indentation}  " : nil
        body_content[correction_start...correction_end] =
          switch_block_recursive(document, nested_block, next_indentation)
      end

      indentation ? body_content.gsub(";", "\n") : "#{body_content.gsub("\n", ";")} "
    end

    # ── locating ─────────────────────────────────────────────────────────────

    # Deepest node of one of TYPES covering byte offset INDEX, plus the node
    # directly above it on the covering path (any type) — the same pair
    # ruby-lsp's RubyDocument.locate/NodeContext provides. Like ruby-lsp's
    # `closest = node` seed, a miss falls back to the WALKED ROOT (that's what
    # makes a class-less "Create Attribute Accessor" insert at Program scope),
    # never nil.
    def locate_path(node, index, types)
      root = node
      found = nil
      parent = nil
      prev = nil
      while node && index
        found, parent = node, prev if types.include?(node.class)
        prev = node
        node = node.compact_child_nodes.find do |c|
          c.location.start_offset <= index && index <= c.location.end_offset
        end
      end
      found ? [found, parent] : [root, nil]
    end

    # First node (document order) of one of TYPES lying fully inside the byte
    # span — ruby-lsp's locate_first_within_range.
    def first_within(node, span, types)
      return nil unless span
      s, e = span
      return nil unless s && e
      queue = [node]
      until queue.empty?
        n = queue.shift
        next unless n.is_a?(Prism::Node)
        loc = n.location
        return n if types.include?(n.class) && loc.start_offset >= s && loc.end_offset <= e
        queue.concat(n.compact_child_nodes)
      end
      nil
    end

    # ── small helpers ────────────────────────────────────────────────────────

    def offset_of(document, position)
      Locator.position_to_byte_offset(document.text, position)
    end

    def byte_span(document, range)
      [offset_of(document, range[:start]), offset_of(document, range[:end])]
    end

    # Leading-space count without a regex (house rule: no regex on source).
    def leading_spaces(line)
      i = 0
      i += 1 while line.getbyte(i) == 0x20
      i
    end

    def workspace_edit(action, edits)
      {
        documentChanges: [
          {
            textDocument: { uri: action.dig(:data, :uri), version: nil },
            edits: edits,
          },
        ],
      }
    end
  end
end
