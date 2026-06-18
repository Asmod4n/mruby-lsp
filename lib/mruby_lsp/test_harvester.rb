# frozen_string_literal: true

require "prism"

module MrubyLsp
  # Harvest method return types from a test suite. mruby's tests run against the
  # real VM, so a passing assertion encodes a VM-true return type -- the source of
  # truth this project already trusts, read off a corpus of call sites instead of
  # guessed from prose (call-seq) or borrowed from CRuby (rbs core).
  #
  # Signal tiers, strongest first:
  #   direct  -- assert_kind_of / float / complex / rational / same / nil /
  #              true / false: the assertion NAMES the type. Authoritative.
  #   equal   -- assert_equal(literal, call): the type leaks through the value.
  #              Trusted only when every observation agrees; a varying equal type
  #              is a content leak (the test's data, not a signature) -> dropped.
  #
  # Content accessors ([] / at / first / fetch / ...) are dropped outright: their
  # return is an element of the receiver, so the observed type is whatever the
  # test put in the container, never a signature. The list is exactly the core
  # methods whose rbs-core return IS the element type variable.
  #
  # Output: { "Class#method" => "RbsType" }, e.g. { "IO#read" => "String?" }.
  # Pure over source strings (Prism only, no VM, no I/O), so it unit-tests offline.
  module TestHarvester
    module_function

    # Core collection methods returning an element of the receiver (the element
    # type variable in rbs core). Dropped wherever they appear, on any receiver:
    # these names are content accessors by inheritance (Enumerable#first, etc.).
    CONTENT_ACCESSORS = %i[
      [] []= at default default= delete delete_at detect dig fetch find first
      key last max min pop rfind sample shift slice slice!
    ].freeze

    # assert_* helpers that NAME a concrete type directly.
    DIRECT_TYPE = {
      assert_float: "Float", assert_complex: "Complex", assert_rational: "Rational"
    }.freeze

    ASSERTIONS = (%i[
      assert_kind_of assert_nil assert_true assert_false assert_same assert_equal
    ] + DIRECT_TYPE.keys).freeze

    # Literal node class -> the Ruby class it evaluates to.
    LITERAL = {
      Prism::StringNode => "String", Prism::InterpolatedStringNode => "String",
      Prism::XStringNode => "String", Prism::SymbolNode => "Symbol",
      Prism::IntegerNode => "Integer", Prism::FloatNode => "Float",
      Prism::RationalNode => "Rational", Prism::ImaginaryNode => "Complex",
      Prism::ArrayNode => "Array", Prism::HashNode => "Hash",
      Prism::RangeNode => "Range", Prism::RegularExpressionNode => "Regexp",
      Prism::TrueNode => "bool", Prism::FalseNode => "bool", Prism::NilNode => "nil"
    }.freeze

    CONSTRUCTORS = %i[new open for].freeze

    # One source string, or an array of them (one per test file) -> the merged
    # { "Class#method" => "RbsType" } map. Observations accumulate across files.
    def harvest(sources)
      obs = Hash.new { |h, k| h[k] = { direct: [], equal: [] } }
      Array(sources).each { |s| harvest_one(s, obs) }
      resolve(obs)
    end

    # ---- per-file pass ----

    def harvest_one(src, obs)
      result = Prism.parse(src)
      return unless result.success?
      root = result.value
      types = local_types(root)
      walk(root) do |n|
        record(n, types, obs) if assertion?(n)
      end
    end

    def record(call, types, obs)
      args = call.arguments&.arguments || []
      case call.name
      when :assert_kind_of
        pin(obs, args[1], types, const_name(args[0]), :direct)
      when :assert_float, :assert_complex, :assert_rational
        args.each { |a| pin(obs, a, types, DIRECT_TYPE[call.name], :direct) }
      when :assert_nil
        pin(obs, args[0], types, "nil", :direct)
      when :assert_true, :assert_false
        pin(obs, args[0], types, "bool", :direct)
      when :assert_same
        # assert_same(exp, act) is identity: act IS exp, so act's type is exp's.
        pin(obs, args[1], types, receiver_class(args[0], types), :direct)
      when :assert_equal
        a, b = args[0], args[1]
        if call_recv?(b) then pin(obs, b, types, literal_type(a), :equal)
        elsif call_recv?(a) then pin(obs, a, types, literal_type(b), :equal)
        end
      end
    end

    # Record an observation for a `recv.meth` subject, when it is attributable to
    # a receiver class, carries a type, and is not a content accessor.
    def pin(obs, subject, types, type, tier)
      return unless type && call_recv?(subject)
      return if CONTENT_ACCESSORS.include?(subject.name)
      klass = receiver_class(subject.receiver, types)
      return unless klass
      obs["#{klass}##{subject.name}"][tier] << type
    end

    # ---- resolution ----

    def resolve(obs)
      out = {}
      obs.each do |key, tiers|
        direct = tiers[:direct].uniq
        eq = tiers[:equal].uniq
        # equal-literal contributes only when every observation agrees: a single
        # consistent type is real signal (read -> String), a varying one is a
        # content leak (the test's data) and is discarded. direct types are
        # always kept; the result is their union.
        equal_types = eq.size == 1 ? eq : []
        types = direct | equal_types
        out[key] = render(types) unless types.empty?
      end
      out
    end

    # A set of class names (may include "nil"/"bool") -> an rbs type string.
    def render(types)
      nilable = types.include?("nil")
      rest = (types - ["nil"]).sort
      return "nil" if rest.empty?
      body = rest.size == 1 ? rest.first : "(#{rest.join(" | ")})"
      nilable ? "#{body}?" : body
    end

    # ---- attribution ----

    # name -> [[offset, class], ...]: local-variable assignments and the block
    # parameters of `Klass.open/new/for { |x| }`. A use resolves to the nearest
    # binding at or before its offset.
    def local_types(root)
      entries = Hash.new { |h, k| h[k] = [] }
      walk(root) do |n|
        case n
        when Prism::LocalVariableWriteNode
          t = receiver_class(n.value, entries)
          entries[n.name] << [n.location.start_offset, t] if t
        when Prism::CallNode
          next unless constructor?(n) && n.block.is_a?(Prism::BlockNode)
          params = n.block.parameters
          next unless params.is_a?(Prism::BlockParametersNode)
          param = params.parameters&.requireds&.first
          next unless param.respond_to?(:name)
          entries[param.name] << [n.block.location.start_offset, n.receiver.name.to_s]
        end
      end
      entries
    end

    def lookup(types, name, offset)
      types[name].select { |off, _| off <= offset }.max_by(&:first)&.last
    end

    # The class an expression evaluates to, for attribution: a literal, a
    # `Klass.new/open/for`, a constant, or a traced local variable.
    def receiver_class(node, types)
      return nil unless node
      literal_type(node) ||
        case node
        when Prism::CallNode
          node.receiver.name.to_s if constructor?(node)
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::LocalVariableReadNode
          lookup(types, node.name, node.location.start_offset)
        end
    end

    def constructor?(call)
      call.is_a?(Prism::CallNode) &&
        call.receiver.is_a?(Prism::ConstantReadNode) &&
        CONSTRUCTORS.include?(call.name)
    end

    # ---- small helpers ----

    def assertion?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && ASSERTIONS.include?(node.name)
    end

    def call_recv?(node)
      node.is_a?(Prism::CallNode) && !node.receiver.nil?
    end

    def literal_type(node)
      LITERAL[node.class]
    end

    def const_name(node)
      node.name.to_s if node.is_a?(Prism::ConstantReadNode)
    end

    def walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| walk(c, &blk) }
    end
  end
end
