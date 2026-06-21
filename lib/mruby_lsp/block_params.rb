# frozen_string_literal: true

require "prism"
require_relative "param_format" # GetArgs paren helpers, reused for the C scan

module MrubyLsp
  # Derive a method's block parameter NAMES from its source -- the names a human
  # would naturally write in `do |...|` -- by reading what the method actually
  # hands its block: `yield a, b` (or `blk.call(a, b)`) in Ruby, `mrb_yield(mrb,
  # b, arg)` in C. This is the source-of-truth approach the rest of the server
  # uses: suggest the names the method itself wrote, never a convention guess.
  # nil whenever the method does not yield, or yields nothing we can name.
  module BlockParams
    module_function

    # ── Ruby (.rb): the first `yield`/block-call whose args are all nameable ──
    def from_ruby(def_node)
      return nil unless def_node.is_a?(Prism::DefNode) && def_node.body

      blk = def_node.parameters&.block&.name&.to_s
      first_named_yield(def_node.body, blk)
    end

    def first_named_yield(node, blk)
      return nil unless node.is_a?(Prism::Node)

      args = yield_arguments(node, blk)
      if args
        names = args.map { |a| arg_name(a) }
        return names if !names.empty? && names.none?(&:nil?)
      end
      node.compact_child_nodes.each do |child|
        found = first_named_yield(child, blk)
        return found if found
      end
      nil
    end

    # The several ways a method hands values to its block, when <blk> is its
    # block parameter: `<blk>.call(a)`, `<blk>.(a)` (sugar -> :call), `<blk>[a]`,
    # and `<blk>.yield(a)`.
    BLOCK_CALL = %i[call [] yield].freeze

    # The arguments a node hands the block: a bare `yield`, or one of the
    # block-call forms above. nil for anything else.
    def yield_arguments(node, blk)
      case node
      when Prism::YieldNode
        node.arguments&.arguments || []
      when Prism::CallNode
        if blk && BLOCK_CALL.include?(node.name) &&
           node.receiver.is_a?(Prism::LocalVariableReadNode) &&
           node.receiver.name.to_s == blk
          node.arguments&.arguments || []
        end
      end
    end

    # A block-parameter name for a yielded expression, or nil if it has none we'd
    # want: a local/ivar/cvar read (sigil stripped), or a no-arg call (`e.value`
    # -> "value", a bare `item` parsed as a call -> "item").
    def arg_name(node)
      case node
      when Prism::LocalVariableReadNode
        node.name.to_s
      when Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode
        node.name.to_s.delete("@")
      when Prism::CallNode
        node.arguments.nil? && node.block.nil? && node.name.to_s.match?(/\A[a-z_]\w*\z/) ? node.name.to_s : nil
      end
    end

    # ── C/C++ (.c/.cxx/.h/...): the value handed to a single-value mrb_yield ──
    # `mrb_yield(mrb, b, ARG)` is the only single-value form; we name ARG when
    # it's a plain identifier. The other three in the family pass an argv ARRAY
    # with no per-value name, so they produce no scaffold (never a guess):
    #   mrb_yield_argv(mrb, b, argc, argv)
    #   mrb_yield_cont(mrb, b, self, argc, argv)
    #   mrb_yield_with_class(mrb, b, argc, argv, self, c)
    # The `\bmrb_yield\s*\(` scan matches only the bare `mrb_yield(`, never those
    # (a `_` follows the name, not `(`). We take the first call with a nameable
    # value. body: a C function body, already bounded to the one function.
    def from_c(body)
      return nil unless body

      # Track the variable that HOLDS the block: the `&` capture in mrb_get_args.
      # A yield/funcall counts only when this variable is its block argument, so
      # `mrb_funcall(mrb, other, "call", ...)` on some unrelated callable is not
      # mistaken for the block. nil (no `&` parsed) -> fall back to position.
      blk = block_var(body)

      # mrb_yield(mrb, BLOCK, VALUE) -- BLOCK is arg 2, the value arg 3.
      each_call(body, "mrb_yield") do |args|
        next unless args.length >= 3
        next if blk && GetArgs.varname(args[1]) != blk

        name = GetArgs.varname(args[2])
        return [name] if name
      end
      # mrb_funcall(mrb, BLOCK, "call", argc, V1, V2, ...) -- the proc invoked the
      # way `block.call(...)` would in Ruby; the variadic values follow argc. The
      # _argv / _id / _with_block forms carry an array or symbol id with no
      # per-value name, so (like the argv yields) they get no scaffold.
      each_call(body, "mrb_funcall") do |args|
        next unless args.length > 4
        next if blk && GetArgs.varname(args[1]) != blk
        next unless GetArgs.string_literal(args[2]) == "call"

        names = args[4..].map { |a| GetArgs.varname(a) }
        return names if names.none?(&:nil?)
      end
      nil
    end

    # The C variable bound to the block, from the function's mrb_get_args `&`
    # directive (GetArgs already recovers it). nil when there is no parseable
    # `mrb_get_args` or it captures no block.
    def block_var(body)
      specs = GetArgs.specs(body) or return nil
      pair = specs.find { |kind, _name| kind == :block }
      pair && pair[1]
    end

    # Yield the top-level argument list of each `<fname>(` call in body. The exact
    # name is matched, so `mrb_yield(` never catches `mrb_yield_argv(` and
    # `mrb_funcall(` never catches `mrb_funcall_with_block(` (a `_` follows, not
    # `(`).
    def each_call(body, fname)
      re = /\b#{Regexp.escape(fname)}\s*\(/
      pos = 0
      while (m = body.match(re, pos))
        args = GetArgs.split_top(GetArgs.balanced(body[m.end(0)..]))
        yield(args) if args
        pos = m.end(0)
      end
    end
  end
end
