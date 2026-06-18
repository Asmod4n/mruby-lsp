# frozen_string_literal: true

require "rbs"

module MrubyLsp
  # Inline method-type annotations -- parsed by rbs, not by us. We own no parser.
  #
  # We use RBS inline syntax. The marker is `#:` in Ruby (mrblib) and `//:` in C;
  # in both it sits on ONE dedicated line directly above the method -- in C, the
  # line above clangd's declaration anchor (the return-type/storage line):
  #
  #     #: (Integer, String) -> Array        //: (Integer, String) -> Array
  #     def push(n, s)                        static mrb_value
  #                                           my_method(mrb_state *mrb, mrb_value self)
  #
  # We strip the marker -- a prefix check, NOT a parser -- and hand the bare
  # method type to RBS::Parser.parse_method_type. rbs does all the parsing, so
  # the full RBS method-type grammar works (optional/splat/keyword args, generics,
  # unions, void/untyped) and anyone who already knows RBS can write it. rbs never
  # sees the marker, only the type.
  #
  # A line that is not a marker, or a payload rbs rejects, yields nil -> the
  # method stays untyped. The annotation is external free text, not our own code,
  # so rejecting it whole is correct, not a swallowed bug.
  module InlineType
    MARKERS = ["//:", "#:"].freeze

    module_function

    # A full source line -> RBS::MethodType or nil. Only a dedicated line whose
    # first non-space content is a marker counts; an inline trailing comment
    # never matches.
    def extract(line)
      s = line.strip
      m = MARKERS.find { |mk| s.start_with?(mk) }
      return nil unless m

      parse(s[m.length..])
    end

    # A bare method type (no marker) -> RBS::MethodType or nil.
    def parse(payload)
      payload = payload.strip
      return nil if payload.empty?

      RBS::Parser.parse_method_type(payload)
    rescue RBS::ParsingError
      nil
    end

    # The class name of a single rbs type for the resolver to look up against the
    # VM, or nil when there is nothing concrete (void, untyped, a union, a
    # singleton, an optional, ...). Only a plain class instance yields a name:
    # "::Foo" -> "::Foo", "Array[X]" -> "Array", everything else -> nil -> untyped.
    def class_name_of(type)
      type.is_a?(RBS::Types::ClassInstance) ? type.name.to_s : nil
    end

    # The return type's class name. "(Integer) -> ::Foo" -> "::Foo".
    def return_class_name(method_type)
      class_name_of(method_type.type.return_type)
    end

    # The class name of the positional parameter at `index` (0-based), or nil.
    # The annotation's positionals (required then optional, in source order) line
    # up with the def's positionals, so the caller passes the param's index in
    # that same order. "(Socket) -> void" #0 -> "Socket"; "(String, ?Numeric) ->
    # void" #1 -> "Numeric".
    def param_class_name(method_type, index)
      t = positional_types(method_type)[index]
      t && class_name_of(t)
    end

    def positional_types(method_type)
      fn = method_type.type
      (fn.required_positionals + fn.optional_positionals).map(&:type)
    end
  end
end
