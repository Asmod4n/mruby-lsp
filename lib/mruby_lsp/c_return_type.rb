# frozen_string_literal: true

module MrubyLsp
  # Stage 3 core, pure: given a clangd `textDocument/ast` subtree for a single C
  # function, infer the Ruby class its return value carries. Every mruby C method
  # has the SAME C signature (`mrb_value f(mrb_state*, mrb_value)`), so the type
  # is NOT in the signature — it is in which mrb_value-constructor the function's
  # return expressions use. This is the C analogue of the irep terminal-opcode map
  # (Stage 2), with the same rule: only a type-unambiguous, UNANIMOUS result is
  # accepted; any branch, unknown constructor, or disagreement -> nil. Never guess.
  #
  # Pure over the AST hash (no clangd here), so it unit-tests offline against
  # captured trees. The clangd client supplies the tree at runtime.
  module CReturnType
    module_function

    # mrb_value constructor (by callee name) -> Ruby class. Only unambiguous ones;
    # mrb_bool_value (True OR False), mrb_obj_value/mrb_cptr_value (any class),
    # mrb_obj_new (the arg's class, not statically the callee's) are deliberately
    # ABSENT -> nil. Prefix-grouped for the families that have many spellings.
    EXACT = {
      "mrb_nil_value"     => "NilClass",
      "mrb_true_value"    => "TrueClass",
      "mrb_false_value"   => "FalseClass",
      "mrb_fixnum_value"  => "Integer",
      "mrb_int_value"     => "Integer",
      "mrb_integer_value" => "Integer",
      "mrb_float_value"   => "Float",
      "mrb_symbol_value"  => "Symbol",
      "mrb_range_new"     => "Range",
      "mrb_hash_new"      => "Hash",
      "mrb_hash_new_capa" => "Hash",
      "mrb_assoc_new"     => "Array",  # a 2-element array
    }.freeze

    # Families where any spelling under the prefix yields the same class.
    PREFIX = [
      ["mrb_str_",  "String"],   # mrb_str_new, _new_cstr, _new_lit, _dup, _cat*, _plus ...
      ["mrb_ary_",  "Array"],    # mrb_ary_new, _new_capa, _new_from_values, _splat ...
      ["mrb_hash_", "Hash"],     # _new variants already EXACT; covers _dup etc.
    ].freeze

    CAST_KINDS = %w[ImplicitCast Paren CStyleCast ConstantExpr ExprWithCleanups].freeze

    # node: the clangd AST node for the function (kind "Function"). -> class | nil.
    def of(function_node)
      return nil unless function_node.is_a?(Hash)
      body = children(function_node).find { |c| c[:kind] == "Compound" }
      return nil unless body
      rets = []
      collect_returns(body, rets)
      return nil if rets.empty?
      types = rets.map { |r| return_type(r) }
      return nil if types.any?(&:nil?)   # an unprovable path -> can't claim a single type
      types.uniq.size == 1 ? types.first : nil
    end

    # Map a single mrb_value-constructor callee name to a class, or nil.
    def constructor_class(name)
      return nil unless name
      EXACT[name] || PREFIX.find { |pre, _| name.start_with?(pre) }&.last
    end

    # --- internals -------------------------------------------------------------

    def collect_returns(node, out)
      return unless node.is_a?(Hash)
      # Do not descend into a nested function/lambda (C has none, but be safe).
      return if node[:kind] == "Function" && !out.empty?
      out << node if node[:kind] == "Return"
      children(node).each { |c| collect_returns(c, out) }
    end

    def return_type(return_node)
      expr = children(return_node).find { |c| c[:role] == "expression" }
      type_of_expr(expr)
    end

    def type_of_expr(node)
      node = unwrap(node)
      return nil unless node.is_a?(Hash)
      case node[:kind]
      when "Call" then constructor_class(callee_name(node))
      else nil  # DeclRef (e.g. `return self`), Member, literal sans constructor -> unknown
      end
    end

    # First child of a Call is the callee; unwrap casts to its DeclRef name.
    def callee_name(call)
      callee = children(call).find { |c| c[:role] == "expression" }
      callee = unwrap(callee)
      callee && callee[:kind] == "DeclRef" ? callee[:detail] : nil
    end

    def unwrap(node)
      node = first_expr_child(node) while node.is_a?(Hash) && CAST_KINDS.include?(node[:kind])
      node
    end

    def first_expr_child(node)
      children(node).find { |c| c[:role] == "expression" }
    end

    def children(node)
      node.is_a?(Hash) ? Array(node[:children]) : []
    end
  end
end
