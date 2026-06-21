# frozen_string_literal: true

require "prism"
require_relative "param_format" # GetArgs paren helpers, reused for the C scan

module MrubyLsp
  # Derive a method's block parameters from what it hands its block: `yield a, b`
  # / `blk.call(a, b)` in Ruby, `mrb_yield(mrb, b, arg)` / `mrb_funcall(mrb, b,
  # "call", argc, ...)` in C. Source is the truth -- we use the names the method
  # itself wrote.
  #
  # Returns one of:
  #   nil   -- the method does not yield (no block scaffold)
  #   []    -- it yields zero values (a block with no |params|)
  #   [..]  -- one entry per yielded value: a String (the source name) or nil
  #            (the value has no name -- e.g. `yield self[idx]` -- so the caller
  #            renders an editable ${n:item} placeholder, never a guessed name)
  module BlockParams
    module_function

    # ── Ruby (.rb) ──────────────────────────────────────────────────────────
    def from_ruby(def_node)
      return nil unless def_node.is_a?(Prism::DefNode) && def_node.body

      blk = def_node.parameters&.block&.name&.to_s
      yields = []
      collect_yields(def_node.body, blk, yields)
      return nil if yields.empty?

      # The most informative yield (most values); a bare guard `yield` loses to a
      # later `yield a, b`.
      yields.max_by(&:length).map { |arg| arg_name(arg) }
    end

    def collect_yields(node, blk, acc)
      return unless node.is_a?(Prism::Node)

      args = yield_arguments(node, blk)
      acc << args if args
      node.compact_child_nodes.each { |child| collect_yields(child, blk, acc) }
    end

    # The values a node hands the block ([] for a bare `yield`), or nil if the
    # node isn't a block invocation. <blk> is the method's block parameter; the
    # several call forms are `<blk>.call(a)`, `<blk>.(a)` (-> :call), `<blk>[a]`,
    # `<blk>.yield(a)`.
    BLOCK_CALL = %i[call [] yield].freeze
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
    # want as a name: a local/ivar/cvar read (sigil stripped), or a no-arg call
    # (`e.value` -> "value", a bare `item` parsed as a call -> "item"). Anything
    # else (an index `self[idx]`, an arithmetic expr, a literal) -> nil.
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

    # ── C/C++ (.c/.cxx/.h/...) ──────────────────────────────────────────────
    # Track the variable holding the block (the mrb_get_args `&` capture) and
    # follow it. Named forms: `mrb_yield(mrb, blk, V)` (one value) and
    # `mrb_funcall(mrb, blk, "call", argc, V1, V2, ...)` (the variadic values).
    # The argv-family (`mrb_yield_argv`/`_cont`/`_with_class`, `mrb_funcall_argv`)
    # pass an array with no per-value name -> it still yields, so one editable
    # placeholder rather than nothing.
    ARGV_BLOCK_FNS = %w[mrb_yield_argv mrb_yield_cont mrb_yield_with_class mrb_funcall_argv].freeze

    def from_c(body)
      return nil unless body

      blk = block_var(body)
      invocations = []
      each_call(body, "mrb_yield") do |args|
        next if blk && GetArgs.varname(args[1]) != blk

        invocations << [args[2]] if args.length >= 3
      end
      each_call(body, "mrb_funcall") do |args|
        next if blk && GetArgs.varname(args[1]) != blk
        next unless GetArgs.string_literal(args[2]) == "call"

        invocations << args[4..] if args.length > 4
      end
      unless invocations.empty?
        return invocations.max_by(&:length).map { |a| GetArgs.varname(a) }
      end

      block_argv_invoked?(body, blk) ? [nil] : nil
    end

    # The C variable bound to the block, from mrb_get_args' `&` (GetArgs recovers
    # it). nil with no parseable mrb_get_args / no block capture.
    def block_var(body)
      specs = GetArgs.specs(body) or return nil
      pair = specs.find { |kind, _name| kind == :block }
      pair && pair[1]
    end

    # Is the block invoked through an argv-family call (yields, but no nameable
    # per-value)? Those take the block as argument 2, like the named forms.
    def block_argv_invoked?(body, blk)
      ARGV_BLOCK_FNS.any? do |fn|
        invoked = false
        each_call(body, fn) { |args| invoked ||= (!blk || GetArgs.varname(args[1]) == blk) }
        invoked
      end
    end

    # Yield the top-level argument list of each `<fname>(` call in body. The exact
    # name is matched, so `mrb_yield(` never catches `mrb_yield_argv(` and
    # `mrb_funcall(` never catches `mrb_funcall_argv(` (a `_` follows, not `(`).
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
