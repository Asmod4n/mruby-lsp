# frozen_string_literal: true

module MrubyLsp
  # Union types: "one of these proven classes", spelled as ONE sorted, deduped
  # string -- "Pq::Result | Pq::Result::Error". A string (not an array) so every
  # existing pipeline that passes bare class names (Entry#return_type, the
  # hover/completion funnels, the harvested-type strings that already carry `|`)
  # keeps working unchanged; a one-member union IS the bare class name, so
  # monomorphic code sees byte-for-byte today's behavior.
  #
  # A union is never a guess: every member was proven (AST terminal, `#:`
  # annotation, rescue class list). If ANY alternative is unknown the whole
  # type is nil -- `of` enforces that. There is deliberately NO width cap: a
  # wide union is exactly what the code says; collapsing it to unknown would
  # discard truth. Long renderings are a presentation concern, not a type one.
  #
  # All member handling lives here so no consumer hand-rolls `split("|")`.
  # The separator is a fixed delimiter in a name we built ourselves -- not
  # structured input, no regex.
  module UnionType
    SEP = " | "

    module_function

    # Proven member names -> the union type. One name -> that name (fast path).
    # Any nil/empty member, or no members -> nil (unknown): unions contain only
    # proven alternatives. Nested unions in the input flatten.
    def of(names)
      return nil if names.nil? || names.empty?
      return nil if names.any? { |n| n.nil? || n.empty? }
      flat = names.flat_map { |n| members(n) }.uniq.sort
      flat.size == 1 ? flat.first : flat.join(SEP)
    end

    def union?(type)
      type.is_a?(String) && type.include?("|")
    end

    # "A | B" -> ["A", "B"]; a bare name -> [name]; nil -> [].
    def members(type)
      return [] unless type.is_a?(String)
      type.split("|").map(&:strip).reject(&:empty?)
    end

    def member?(type, name)
      members(type).include?(name)
    end

    # Keep only the members named by `other` (a class name or union). Narrowing
    # that would empty the union returns nil -- the CALLER falls back to the
    # unnarrowed type (a guard we can't reconcile is not license to guess).
    def intersect(type, other)
      of(members(type) & members(other))
    end

    # Drop the members named by `other`. Empties -> nil, same caller fallback.
    def subtract(type, other)
      of(members(type) - members(other))
    end
  end
end
