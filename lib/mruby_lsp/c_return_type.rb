# frozen_string_literal: true

require "set"

module MrubyLsp
  # Stage 3 core, pure: given a clangd `textDocument/ast` subtree for a single C
  # function, infer the Ruby class its return value carries. Every mruby C method
  # has the SAME C signature (`mrb_value f(mrb_state*, mrb_value)`), so the type
  # is NOT in the signature — it is in which mrb_value-constructor the function's
  # return expressions use. This is the C analogue of the irep terminal-opcode map
  # (Stage 2), with the same rule: only a type-unambiguous, UNANIMOUS result is
  # accepted; any branch, unknown constructor, or disagreement -> nil. Never guess.
  #
  # Beyond fixed-class constructors (mrb_str_new -> String) this also recognises a
  # CONSTRUCTOR that returns a fresh instance of the RECEIVER class — the common
  # `Klass.for_fd` / `Klass.allocate` shape, where the C builds an object whose
  # class is the method's own receiver (`mrb_obj_alloc(mrb, ttype, mrb_class_ptr(
  # klass))`). That can't name a fixed class (it depends on the call-site receiver,
  # File.for_fd -> File vs IO.for_fd -> IO), so it yields the RECEIVER sentinel;
  # the caller (type inference) resolves it against the actual receiver. The fresh
  # object often flows through one or more helpers (`return io_init(mrb, obj)`),
  # so a small, depth-bounded interprocedural step follows helpers that hand back
  # one of their own arguments. The helper-AST supply is injected (resolve_callee)
  # — this file stays pure over the AST hash and unit-tests offline.
  module CReturnType
    module_function

    # Sentinel: the function returns a fresh instance of its RECEIVER class. Not a
    # fixed class name (depends on the call site), so the caller substitutes the
    # receiver. A Symbol so it can never be mistaken for a class-name String.
    RECEIVER = :__receiver__

    # Guard against deep/cyclic expression walks (macro expansions nest casts).
    MAX_DEPTH = 40

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

    # Allocators that build a FRESH object of a given class. Value = the index of
    # the CLASS argument among the call's value arguments (0-based, arg 0 = the
    # leading mrb_state*). When that class argument is the function's own receiver
    # class — `mrb_class_ptr(<receiver param>)` — the result is a fresh receiver
    # instance (RECEIVER). These are NOT in EXACT precisely because the class is
    # not fixed; only when it resolves to the receiver do we claim a type.
    ALLOCATORS = {
      "mrb_obj_alloc"          => 2,  # mrb_obj_alloc(mrb, vtype, class)
      "mrb_obj_new"            => 1,  # mrb_obj_new(mrb, class, argc, argv)
      "mrb_class_new_instance" => 3,  # mrb_class_new_instance(mrb, argc, argv, class)
    }.freeze

    # mrb_value wrappers that pass their argument's "freshness" straight through:
    # mrb_obj_value(RObject*) just boxes a pointer, so its type is its argument's.
    PASSTHROUGH = %w[mrb_obj_value].freeze

    CAST_KINDS = %w[ImplicitCast Paren CStyleCast ConstantExpr ExprWithCleanups].freeze

    # node: the clangd AST node for the function (kind "Function").
    # -> class String | RECEIVER | nil. resolve_callee, if given, is a callable
    # name -> classify-result for same-file helpers (depth-bounded by the caller).
    def of(function_node, resolve_callee: nil)
      r = classify_function(function_node, resolve_callee)
      r.is_a?(String) || r == RECEIVER ? r : nil
    end

    # As `of`, but also exposes the internal `[:arg, k]` result (the function hands
    # back its own k-th argument unchanged). Used by the interprocedural step so a
    # caller can substitute its own argument; never surfaced as a user type.
    def classify(function_node, resolve_callee: nil)
      classify_function(function_node, resolve_callee)
    end

    # Map a single mrb_value-constructor callee name to a fixed class, or nil.
    def constructor_class(name)
      return nil unless name
      EXACT[name] || PREFIX.find { |pre, _| name.start_with?(pre) }&.last
    end

    # --- internals -------------------------------------------------------------

    # -> class String | RECEIVER | [:arg, k] | nil. Unanimous over all returns.
    def classify_function(function_node, resolve_callee)
      return nil unless function_node.is_a?(Hash)
      body = children(function_node).find { |c| c[:kind] == "Compound" }
      return nil unless body
      params = param_names(function_node)
      ctx = {
        params:   params,
        locals:   collect_locals(body),
        receiver: params[1],   # the mrb_value self, standard mruby C signature
        resolve:  resolve_callee,
      }
      rets = []
      collect_returns(body, rets)
      return nil if rets.empty?
      results = rets.map { |r| classify_return(r, ctx) }
      return nil if results.any?(&:nil?)   # an unprovable path -> can't claim a type
      results.uniq.size == 1 ? results.first : nil
    end

    def classify_return(return_node, ctx)
      classify_expr(children(return_node).find { |c| c[:role] == "expression" }, ctx)
    end

    # -> class String | RECEIVER | [:arg, k] | nil.
    def classify_expr(node, ctx)
      node = unwrap(node)
      return nil unless node.is_a?(Hash)
      case node[:kind]
      when "Call"    then classify_call(node, ctx)
      when "DeclRef" then classify_ref(node, ctx)
      else nil
      end
    end

    def classify_call(call, ctx)
      name = callee_name(call)
      return nil unless name
      if (cls = constructor_class(name))
        return cls
      end
      if (ci = ALLOCATORS[name])
        return denotes_receiver_class?(value_args(call)[ci], ctx) ? RECEIVER : nil
      end
      if PASSTHROUGH.include?(name)
        return classify_expr(value_args(call)[0], ctx)
      end
      classify_via_callee(call, name, ctx)   # interprocedural helper hop
    end

    # A bare identifier in return position: a local resolves to its initializer; a
    # parameter means "this function returns that argument" ([:arg, k]).
    def classify_ref(node, ctx)
      nm = node[:detail]
      return classify_expr(ctx[:locals][nm], ctx) if ctx[:locals].key?(nm)
      idx = ctx[:params].index(nm)
      return [:arg, idx] if idx
      # clangd's ranged AST sometimes omits ParmVar nodes, leaving params empty.
      # A return of a name that is neither a local nor a known constructor is then
      # the receiver value param (the universal `mrb_value self`, arg index 1).
      ctx[:params].empty? ? [:arg, 1] : nil
    end

    # `return helper(mrb, x, ...)`: ask the injected resolver what `helper` does.
    # If it returns its own argument k, substitute THIS call's argument k and
    # classify that in the current context; a fixed class passes straight through.
    def classify_via_callee(call, name, ctx)
      resolve = ctx[:resolve]
      return nil unless resolve
      sub = resolve.call(name)
      case sub
      when String  then sub
      when RECEIVER then RECEIVER
      when Array   # [:arg, k] -> our k-th argument, in our context
        classify_expr(value_args(call)[sub[1]], ctx)
      end
    end

    # True iff `node` denotes the RECEIVER's class. The obvious spelling is
    # `mrb_class_ptr(<receiver>)`, but `mrb_class_ptr` is a MACRO: in a real TU it
    # expands to `(struct RClass*)(mrb_val_union(klass).p)` — a cast/member/call
    # chain, not a `Call mrb_class_ptr` node. So we don't pattern-match the
    # spelling; we check what the class expression READS: it must derive solely
    # from the receiver mrb_value (`klass`) and nothing else. A fixed class
    # (`mrb_class_get(mrb, "Foo")`) reads `mrb`/a literal, not the receiver, so it
    # correctly does NOT match. Requires the receiver param name to be known.
    def denotes_receiver_class?(node, ctx)
      return false unless ctx[:receiver]
      refs = value_refs(node, ctx, Set.new, 0)
      refs.size == 1 && refs.include?(ctx[:receiver])
    end

    # The set of parameter/local VALUE names an expression ultimately reads,
    # following locals to their initializers and skipping callee names (a called
    # function's identifier is not a value read). Casts/parens/member-accesses are
    # transparent. Used to prove a class pointer is derived only from the receiver.
    def value_refs(node, ctx, acc, depth)
      return acc if depth > MAX_DEPTH
      node = unwrap(node)
      return acc unless node.is_a?(Hash)
      case node[:kind]
      when "DeclRef"
        nm = node[:detail]
        if ctx[:locals].key?(nm)
          value_refs(ctx[:locals][nm], ctx, acc, depth + 1)   # follow the local
        elsif nm
          acc << nm
        end
      when "Call"
        value_args(node).each { |a| value_refs(a, ctx, acc, depth + 1) }  # skip callee
      else
        children(node).select { |c| c[:role] == "expression" }
                      .each { |a| value_refs(a, ctx, acc, depth + 1) }
      end
      acc
    end

    # name -> initializer-expression (or nil for an uninitialised decl) for every
    # Var declared anywhere in the function body. clangd nests a VarDecl under a
    # Decl(Stmt); the Var's expression child (past its type children) is the init.
    def collect_locals(body, out = {})
      return out unless body.is_a?(Hash)
      if body[:kind] == "Var" && body[:detail]
        out[body[:detail]] = children(body).find { |c| c[:role] == "expression" }
      end
      children(body).each { |c| collect_locals(c, out) }
      out
    end

    # Parameter names in order. clangd nests the ParmVar nodes under the function's
    # FunctionProto (type) child, not directly under the Function — look there
    # first, falling back to direct children for tolerance.
    def param_names(function_node)
      proto = children(function_node).find { |c| c[:kind] == "FunctionProto" }
      children(proto || function_node).select { |c| c[:kind] == "ParmVar" }.map { |c| c[:detail] }
    end

    def collect_returns(node, out)
      return unless node.is_a?(Hash)
      # Do not descend into a nested function/lambda (C has none, but be safe).
      return if node[:kind] == "Function" && !out.empty?
      out << node if node[:kind] == "Return"
      children(node).each { |c| collect_returns(c, out) }
    end

    # The value arguments of a Call: every expression child past the callee.
    def value_args(call)
      return [] unless call.is_a?(Hash)
      children(call).select { |c| c[:role] == "expression" }[1..] || []
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
