# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/documentSymbol — a DocumentSymbol[] tree from the buffer's Prism
  # AST. Ports ruby-lsp's listener faithfully (verified against its own
  # expectation suite). Stack-based: class/module/def push a parent; their body
  # symbols attach as children; leave pops.
  #
  # SymbolKind ints: MODULE=2 NAMESPACE=3 CLASS=5 METHOD=6 FIELD=8 CONSTRUCTOR=9
  # FUNCTION=12 VARIABLE=13 CONSTANT=14.
  module DocumentSymbol
    module_function

    MODULE = 2
    NAMESPACE = 3
    CLASS = 5
    METHOD = 6
    FIELD = 8
    CONSTRUCTOR = 9
    FUNCTION = 12
    VARIABLE = 13
    CONSTANT = 14

    ATTR_ACCESSORS = %w[attr_reader attr_writer attr_accessor].freeze

    def response(document)
      root = document.ast.value
      top = { children: [] }
      stack = [top]
      walk(root, stack)
      top[:children]
    end

    # Walk the AST maintaining a parent stack. Container nodes (class/module/def/
    # singleton class) emit a symbol, push it, recurse, then pop. Leaf-symbol
    # nodes emit into the current parent. Everything else just recurses.
    def walk(node, stack)
      return unless node.is_a?(Prism::Node)
      case node
      when Prism::ClassNode
        sym = emit(stack, class_path_name(node.constant_path), CLASS, node.location, node.constant_path.location)
        push_recurse(node, sym, stack)
      when Prism::ModuleNode
        sym = emit(stack, class_path_name(node.constant_path), MODULE, node.location, node.constant_path.location)
        push_recurse(node, sym, stack)
      when Prism::SingletonClassNode
        sym = emit(stack, "<< #{node.expression.slice}", NAMESPACE, node.location, node.expression.location)
        push_recurse(node, sym, stack)
      when Prism::DefNode
        name, kind = def_name_kind(node, stack)
        sym = emit(stack, name, kind, node.location, node.name_loc)
        push_recurse(node, sym, stack)
      when Prism::CallNode
        handle_call(node, stack)
        recurse(node, stack)
      when Prism::AliasMethodNode
        nn = node.new_name
        if nn.is_a?(Prism::SymbolNode) && nn.value
          emit(stack, nn.value, METHOD, nn.location, nn.value_loc)
        end
        recurse(node, stack)
      when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
           Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
        emit(stack, node.name.to_s, CONSTANT, node.location, node.name_loc)
        recurse(node, stack)
      when Prism::ConstantTargetNode
        emit(stack, node.name.to_s, CONSTANT, node.location, node.location)
        recurse(node, stack)
      when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
           Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
        emit(stack, node.target.location.slice, CONSTANT, node.location, node.target.location)
        recurse(node, stack)
      when Prism::ConstantPathTargetNode
        emit(stack, node.location.slice, CONSTANT, node.location, node.location)
        recurse(node, stack)
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
           Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode
        emit(stack, node.name.to_s, FIELD, node.name_loc, node.name_loc)
        recurse(node, stack)
      when Prism::InstanceVariableTargetNode
        emit(stack, node.name.to_s, FIELD, node.location, node.location)
        recurse(node, stack)
      when Prism::ClassVariableWriteNode, Prism::ClassVariableOrWriteNode,
           Prism::ClassVariableAndWriteNode, Prism::ClassVariableOperatorWriteNode
        emit(stack, node.name.to_s, VARIABLE, node.name_loc, node.name_loc)
        recurse(node, stack)
      when Prism::ClassVariableTargetNode
        emit(stack, node.name.to_s, VARIABLE, node.location, node.location)
        recurse(node, stack)
      else
        recurse(node, stack)
      end
    end

    def push_recurse(node, sym, stack)
      stack.push(sym)
      recurse(node, stack)
      stack.pop
    end

    def recurse(node, stack)
      node.compact_child_nodes.each { |c| walk(c, stack) }
    end

    def handle_call(node, stack)
      receiver = node.receiver
      return if receiver && !receiver.is_a?(Prism::SelfNode)
      name = node.name.to_s
      if ATTR_ACCESSORS.include?(name)
        handle_attr(node, stack)
      elsif name == "alias_method"
        handle_alias_method(node, stack)
      end
    end

    def handle_attr(node, stack)
      args = node.arguments
      return unless args
      args.arguments.each do |arg|
        if arg.is_a?(Prism::SymbolNode) && arg.value
          emit(stack, arg.value, FIELD, arg.location, arg.value_loc)
        elsif arg.is_a?(Prism::StringNode) && !arg.content.empty?
          emit(stack, arg.content, FIELD, arg.location, arg.content_loc)
        end
      end
    end

    def handle_alias_method(node, stack)
      args = node.arguments
      return unless args
      first = args.arguments.first
      if first.is_a?(Prism::SymbolNode) && first.value
        emit(stack, first.value, METHOD, first.location, first.value_loc)
      elsif first.is_a?(Prism::StringNode) && !first.content.empty?
        emit(stack, first.content, METHOD, first.location, first.content_loc)
      end
    end

    def def_name_kind(node, stack)
      receiver = node.receiver
      if receiver.is_a?(Prism::SelfNode)
        ["self.#{node.name}", FUNCTION]
      else
        parent = stack.last
        parent_name = parent[:name].to_s if parent.is_a?(Hash) && parent[:name]
        if parent_name && parent_name.start_with?("<<")
          [node.name.to_s, FUNCTION]
        elsif node.name.to_s == "initialize"
          ["initialize", CONSTRUCTOR]
        else
          [node.name.to_s, METHOD]
        end
      end
    end

    def emit(stack, name, kind, range_loc, sel_loc)
      name = "<blank>" if name.to_s.strip.empty?
      sym = {
        name: name,
        kind: kind,
        range: Locator.range_of(range_loc),
        selectionRange: Locator.range_of(sel_loc),
        children: []
      }
      stack.last[:children] << sym
      sym
    end

    def class_path_name(const_node)
      case const_node
      when Prism::ConstantReadNode
        const_node.name.to_s
      when Prism::ConstantPathNode
        begin
          const_node.full_name
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError,
               Prism::ConstantPathNode::MissingNodesInConstantPathError
          # Incomplete/dynamic constant path in a half-typed buffer.
          const_node.slice
        end
      else
        const_node.respond_to?(:slice) ? const_node.slice : const_node.to_s
      end
    end
  end
end
