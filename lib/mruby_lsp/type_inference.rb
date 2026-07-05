# frozen_string_literal: true

require "prism"
require_relative "inline_type"
require_relative "c_return_type"
require_relative "block_params"
require_relative "union_type"

module MrubyLsp
  # Local-variable + method-return type inference. All paths funnel through
  # `type_of` and yield a bare Ruby class name (never a guess, never a provenance
  # marker), so user-visible output is identical regardless of where the type
  # came from — matching ruby-lsp's known (non-guessed) receiver path.
  #
  #   Stage 1: a `def` in the open buffer            -> AST (always fresh per keystroke).
  #   Stage 2: a compiled VM Ruby method (not open)  -> Entry#return_type (irep-derived,
  #            set at populate, refreshed wholesale on rebuild).
  #   Stage 3: a C method                            -> clangd (future).
  #
  # Buffer beats VM: infer_call tries the buffer def first, so an edited method
  # reflects immediately and the stored irep type only applies to compiled-but-
  # not-open methods. The index is threaded optionally; with no index, Stage 1
  # behaviour is unchanged.
  module TypeInference
    module_function

    MAX_DEPTH = 12

    SCOPE_NODES = [
      Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
    ].freeze

    VAR_WRITES = {
      # `=`, `+=`, AND the `||=` / `&&=` forms: `@x ||= {}` initializes @x to a
      # Hash, so its RHS is as good a type source as a plain assignment.
      ivar: [Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
             Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode],
      cvar: [Prism::ClassVariableWriteNode, Prism::ClassVariableOperatorWriteNode,
             Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode],
      gvar: [Prism::GlobalVariableWriteNode, Prism::GlobalVariableOperatorWriteNode,
             Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode],
    }.freeze

    def infer_variable(kind, name, usage_offset, document, index = nil, depth = 0)
      return nil if depth > MAX_DEPTH
      root =
        if kind == :gvar
          document.ast.value
        else
          enclosing_class(document.ast.value, usage_offset)
        end
      return nil unless root
      result = nil
      walk(root) do |node|
        next unless VAR_WRITES[kind].any? { |k| node.is_a?(k) }
        next unless node.name.to_s == name && node.value
        t = type_of(node.value, document, index, depth + 1)
        result = t if t
      end
      return result if result

      # No inferable write in scope. For an ivar, fall back to a DECLARED type
      # (mruby-native-ext-type, via the index). The write wins above — as dynamic
      # as Ruby — and the declaration is the baseline for code that hasn't (yet)
      # assigned the ivar in view. Union declarations resolve to nil in the index.
      if kind == :ivar && index.respond_to?(:ivar_type)
        cls = enclosing_class_name(document.ast.value, usage_offset)
        return index.ivar_type(cls, name) if cls
      end
      nil
    end

    def enclosing_class(root, offset)
      best = nil
      best_span = nil
      walk(root) do |node|
        next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) ||
                    node.is_a?(Prism::SingletonClassNode)
        loc = node.location
        next unless offset >= loc.start_offset && offset <= loc.end_offset
        span = loc.end_offset - loc.start_offset
        if best_span.nil? || span < best_span
          best = node
          best_span = span
        end
      end
      best || root
    end

    # Name of the innermost enclosing class/module ("Object" at top level,
    # mirroring ruby-lsp's main-is-Object rule); nil if it carries no static name.
    def enclosing_class_name(root, offset)
      # Full nesting (CBOR::Diagnose), not just the innermost segment, so the
      # index lookup matches its fully-qualified owner keys.
      names = []
      walk(root) do |node|
        next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        loc = node.location
        next unless offset >= loc.start_offset && offset <= loc.end_offset
        n = constant_node_name(node.constant_path)
        names << n if n
      end
      names.empty? ? "Object" : names.join("::")
    end

    def constant_node_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        p = constant_node_name(node.parent)
        p ? "#{p}::#{node.name}" : node.name.to_s
      else nil
      end
    end

    # The VALUE type of a constant, from its assignment in this buffer's AST
    # (CONST = <literal/typed expr> -> that expr's type). nil if not assigned
    # here or the value's type is unknown -- never guess. Buffer-only: an edit to
    # the assignment reflects immediately; a compiled-only constant stays nil
    # (the VM doesn't reflect constant value classes -- that would be a new op).
    def infer_constant(node, document, index = nil, depth = 0)
      return nil if depth > MAX_DEPTH
      short = constant_short_name(node)
      return nil unless short
      write = find_constant_write(document.ast.value, short)
      return nil unless write && write.value
      type_of(write.value, document, index, depth + 1)
    end

    def constant_short_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.name.to_s   # final segment
      else nil
      end
    end

    # Last assignment to a constant of this (short) name anywhere in the buffer.
    # Constants are normally assigned once; last-write is a safe approximation
    # and avoids ordering games for top-level CONST = ... declarations.
    def find_constant_write(root, short_name)
      found = nil
      walk(root) do |n|
        if n.is_a?(Prism::ConstantWriteNode) && n.name.to_s == short_name
          found = n
        elsif n.is_a?(Prism::ConstantPathWriteNode)
          tgt = n.target
          found = n if tgt.respond_to?(:name) && tgt.name.to_s == short_name
        end
      end
      found
    end

    def infer_local(name, usage_offset, document, index = nil, depth = 0)
      return nil if depth > MAX_DEPTH
      scope = enclosing_scope(document.ast.value, usage_offset)
      write = nearest_write(scope, name, usage_offset)
      # A local can also be born at a BINDING SITE with no write node: a pattern
      # capture (`in Integer => n`, `expr => x`) or a block parameter
      # (`each do |e|`, `_1`, `it`). The latest of write-vs-binding wins, the
      # same last-one-reaches rule writes already follow.
      bind = nearest_binding(scope, name.to_sym, usage_offset, document, index, depth)
      type = anchor = nil
      if bind && (write.nil? || write.location.end_offset < bind[0])
        type = bind[1]
        anchor = bind[0]
      elsif write && write.value
        # A steep-style trailing annotation on the assignment line pins the
        # local: `api = URL("https://…") #: URL::HTTP`. The hand-written pin
        # WINS over RHS inference — it exists exactly for factories that
        # dispatch to different classes (URL()), whose single return type is
        # not inferable and never will be.
        ann = trailing_annotation(document, write.location.start_line)
        type = ann || type_of(write.value, document, index, depth + 1)
        anchor = write.location.end_offset
      else
        # No assignment reaches this use, so `name` may be a method parameter. A
        # param has no LocalVariableWriteNode; its type, if any, comes from the
        # enclosing def's inline annotation (#: (...) -> ...). A later
        # reassignment would have been found above and rightly wins over the
        # annotation. Anchor 0: every guard in scope stands between a param's
        # birth and this use.
        type = param_type_from_annotation(name, usage_offset, document)
        anchor = 0
      end
      # A union collapses back toward a single class through the control-flow
      # guards that dominate this use. Single types skip this entirely -- the
      # monomorphic fast path is byte-for-byte the pre-union behavior.
      narrow_union(type, name.to_sym, anchor, usage_offset, scope)
    end

    # Map a parameter to its annotated class: find the enclosing def, the param's
    # position among the positionals, and the annotation line directly above; the
    # index/VM resolves the returned class name. nil when any link is missing.
    def param_type_from_annotation(name, usage_offset, document)
      defn = enclosing_def(document.ast.value, usage_offset)
      return nil unless defn

      idx = positional_param_names(defn).index(name)
      return nil unless idx

      line = annotation_line_above(document, defn.location.start_line)
      return nil unless line

      mt = InlineType.extract(line)
      mt && InlineType.param_class_name(mt, idx)
    end

    # The return class named by a `#:` annotation on the line directly above the
    # def, or nil. Wins over AST inference (it is the hand-written contract).
    # Returns the class name as written; the caller resolves it through the
    # cursor's nesting like every other inferred type name.
    def return_type_from_annotation(defn, document)
      return nil unless document.respond_to?(:ast)
      ast = document.ast
      return nil unless ast.respond_to?(:comments)
      line = annotation_line_above(document, defn.location.start_line)
      return nil unless line
      mt = InlineType.extract(line)
      mt && InlineType.return_class_name(mt)
    end

    def enclosing_def(root, offset)
      best = nil
      best_span = nil
      walk(root) do |node|
        next unless node.is_a?(Prism::DefNode)
        loc = node.location
        next unless offset >= loc.start_offset && offset <= loc.end_offset
        span = loc.end_offset - loc.start_offset
        if best_span.nil? || span < best_span
          best = node
          best_span = span
        end
      end
      best
    end

    # The def's positional parameter names in source order (required then
    # optional). Destructured slots map to nil so later positions still line up
    # with the annotation's positionals.
    def positional_param_names(defn)
      ps = defn.parameters
      return [] unless ps
      (ps.requireds + ps.optionals).map { |p| p.respond_to?(:name) ? p.name : nil }
    end

    # The raw text of the comment directly above the def -- the annotation line.
    # Raw (leading #: intact) because InlineType reads the marker.
    def annotation_line_above(document, def_start_line)
      document.ast.comments.each do |c|
        # c.location.slice (not c.slice) — Prism::Comment#slice is newer; the
        # location form returns the same text and works across prism versions.
        return c.location.slice if c.location.start_line == def_start_line - 1
      end
      nil
    end

    def enclosing_scope(root, offset)
      best = root
      best_span = nil
      walk(root) do |node|
        next unless SCOPE_NODES.any? { |k| node.is_a?(k) }
        loc = node.location
        next unless offset >= loc.start_offset && offset <= loc.end_offset
        span = loc.end_offset - loc.start_offset
        if best_span.nil? || span < best_span
          best = node
          best_span = span
        end
      end
      best
    end

    def nearest_write(scope, name, usage_offset)
      found = nil
      pruned_walk(scope) do |node|
        next unless node.is_a?(Prism::LocalVariableWriteNode)
        next unless node.name == name
        next unless node.location.end_offset <= usage_offset
        found = node if found.nil? || node.location.end_offset > found.location.end_offset
      end
      found
    end

    # ---- union narrowing: control-flow guards between write and use ----------
    # A union type ("A | B") collapses back toward a single class through the
    # guards that PROVABLY dominate the use site -- pure AST shape + location
    # arithmetic, nothing evaluated. Only guards AFTER the type's anchor (the
    # reaching write/binding) count, so a reassignment between guard and use
    # cancels narrowing for free. A guard that would empty the union is
    # dropped (fall back to the unnarrowed type -- a contradiction is not
    # license to guess). Class-pattern and case/when semantics cannot be
    # monkey-patched in mruby; is_a?/kind_of?/instance_of? redefinition would
    # lie to us the same way it lies to every reader of the code.

    ISA_TESTS = %i[is_a? kind_of? instance_of?].freeze
    FALSY = "FalseClass | NilClass"

    def narrow_union(type, name, anchor, usage_offset, scope)
      return type unless UnionType.union?(type)
      guards = [] # [predicate_offset, :intersect | :subtract, classes]
      pruned_walk(scope) do |node|
        case node
        when Prism::IfNode, Prism::UnlessNode
          if_guard(node, name, anchor, usage_offset, guards)
        when Prism::CaseNode
          case_guard(node, name, anchor, usage_offset, guards)
        when Prism::CaseMatchNode
          case_match_guard(node, name, anchor, usage_offset, guards)
        end
      end
      guards.sort_by!(&:first)
      guards.reduce(type) do |t, (_, op, classes)|
        n = op == :intersect ? UnionType.intersect(t, classes) : UnionType.subtract(t, classes)
        n || t
      end
    end

    def within?(loc, offset) = offset >= loc.start_offset && offset <= loc.end_offset

    # What an if/unless PREDICATE proves about `name`: [:isa, "K"] for
    # name.is_a?(K) / kind_of? / instance_of?, [:truthy] for a bare `name`
    # test, nil when the predicate says nothing usable about it.
    def guard_test(pred, name)
      case pred
      when Prism::LocalVariableReadNode
        [:truthy] if pred.name == name
      when Prism::CallNode
        return nil unless ISA_TESTS.include?(pred.name)
        recv = pred.receiver
        return nil unless recv.is_a?(Prism::LocalVariableReadNode) && recv.name == name
        args = pred.arguments&.arguments
        return nil unless args && args.size == 1
        k = constant_node_name(args.first)
        k && [:isa, k]
      end
    end

    def if_guard(node, name, anchor, usage_offset, guards)
      pred = node.predicate
      return unless pred && pred.location.start_offset >= anchor
      kind, classes = guard_test(pred, name)
      return unless kind
      # What holds when the test PASSES / FAILS:
      pass = kind == :isa ? [:intersect, classes] : [:subtract, FALSY]
      fail_ = kind == :isa ? [:subtract, classes] : [:intersect, FALSY]
      pass, fail_ = fail_, pass if node.is_a?(Prism::UnlessNode)
      off = pred.location.start_offset
      # if carries `subsequent` (else/elsif), unless carries `else_clause`.
      alt = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
      if node.statements && within?(node.statements.location, usage_offset)
        guards << [off, *pass]
      elsif alt && within?(alt.location, usage_offset)
        # else -- or an elsif chain, whose own predicate is collected when the
        # walk reaches the inner IfNode; this test's failure still holds there.
        guards << [off, *fail_]
      elsif usage_offset >= node.location.end_offset && alt.nil? &&
            terminates?(node.statements)
        # `return x if x.is_a?(K)` (also next/break/raise): falling past the
        # guard proves the test FAILED for the remainder of the scope.
        guards << [off, *fail_]
      end
    end

    # Does this branch body unconditionally leave the scope? (Last statement is
    # return/next/break or a bare raise.) Location arithmetic needs nothing
    # more: anything fancier simply doesn't narrow.
    def terminates?(stmts)
      last = stmts.is_a?(Prism::StatementsNode) ? stmts.body.last : stmts
      case last
      when Prism::ReturnNode, Prism::NextNode, Prism::BreakNode then true
      when Prism::CallNode then last.receiver.nil? && last.name == :raise
      else false
      end
    end

    # case x; when A ...: inside a branch whose conditions are all constants,
    # x IS one of them (class === cannot be repointed in mruby); reaching a
    # later branch/else proves every earlier constant condition did NOT match.
    def case_guard(node, name, anchor, usage_offset, guards)
      pred = node.predicate
      return unless pred.is_a?(Prism::LocalVariableReadNode) && pred.name == name
      return unless pred.location.start_offset >= anchor
      off = pred.location.start_offset
      missed = []
      node.conditions.each do |w|
        consts = w.conditions.map { |c| constant_node_name(c) }
        if w.statements && within?(w.statements.location, usage_offset)
          missed.each { |k| guards << [off, :subtract, k] }
          guards << [off, :intersect, UnionType.of(consts)] if consts.all?
          return
        end
        missed.concat(consts.compact)
      end
      return unless node.else_clause && within?(node.else_clause.location, usage_offset)
      missed.each { |k| guards << [off, :subtract, k] }
    end

    # case x; in A ...: same facts as case/when for plain class patterns
    # (including alternations of them). Captures (`in A => e`) already type
    # their own variable via nearest_binding; this narrows the SUBJECT.
    def case_match_guard(node, name, anchor, usage_offset, guards)
      pred = node.predicate
      return unless pred.is_a?(Prism::LocalVariableReadNode) && pred.name == name
      return unless pred.location.start_offset >= anchor
      off = pred.location.start_offset
      missed = []
      node.conditions.each do |cond|
        next unless cond.is_a?(Prism::InNode)
        k = pattern_class_names(cond.pattern)
        if cond.statements && within?(cond.statements.location, usage_offset)
          missed.each { |m| guards << [off, :subtract, m] }
          guards << [off, :intersect, k] if k
          return
        end
        missed << k if k
      end
      return unless node.else_clause && within?(node.else_clause.location, usage_offset)
      missed.each { |m| guards << [off, :subtract, m] }
    end

    # The class name(s) a PLAIN class pattern tests for: a constant, or an
    # alternation of them ("A | B"). Anything with structure/captures -> nil
    # (it may prove more than a class; we only narrow on what's certain).
    def pattern_class_names(pat)
      case pat
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        constant_node_name(pat)
      when Prism::AlternationPatternNode
        UnionType.of([pattern_class_names(pat.left), pattern_class_names(pat.right)])
      end
    end

    # ---- binding sites: pattern captures + block parameters ------------------
    # Locals born without a LocalVariableWriteNode. Same contract as everything
    # else here: a bare class name when the AST proves it, nil otherwise.

    # The latest binding site of `name` reaching usage_offset, as
    # [site_offset, type-or-nil]; nil when no binding site binds this name.
    # A binding counts from its START (a capture target sits inside its own
    # pattern, a block param inside its block), unlike writes which must END
    # before the use.
    def nearest_binding(scope, name, usage_offset, document, index, depth)
      best = nil
      take = lambda do |off, hit|
        best = [off, hit.first] if hit && (best.nil? || off >= best[0])
      end
      pruned_walk(scope) do |node|
        case node
        when Prism::CaseMatchNode
          node.conditions.each do |cond|
            next unless cond.is_a?(Prism::InNode)
            pat = cond.pattern
            next unless pat.location.start_offset <= usage_offset
            take.call(pat.location.start_offset,
                      pattern_binding(pat, name, node.predicate, document, index, depth))
          end
        when Prism::MatchRequiredNode, Prism::MatchPredicateNode
          pat = node.pattern
          next unless pat.location.start_offset <= usage_offset
          take.call(pat.location.start_offset,
                    pattern_binding(pat, name, node.value, document, index, depth))
        when Prism::CallNode
          blk = node.block
          next unless blk.is_a?(Prism::BlockNode)
          loc = blk.location
          # A block param only exists inside its block (innermost block wins:
          # a deeper block starts later, so `>=` in take prefers it).
          next unless usage_offset >= loc.start_offset && usage_offset <= loc.end_offset
          pos, arity = block_param_position(blk, name)
          next unless pos
          take.call(loc.start_offset,
                    [yield_param_type(node, pos, arity, document, index, depth)])
        when Prism::RescueNode
          # `rescue SomeError => e`: the class list IS the type test — matching
          # proves e is one of those classes. A single (uniform) class types e;
          # a bare `rescue => e` catches StandardError, whose methods every
          # subclass instance has, so the baseline class is sound to resolve on.
          ref = node.reference
          next unless ref.is_a?(Prism::LocalVariableTargetNode) && ref.name == name
          next unless ref.location.start_offset <= usage_offset
          take.call(ref.location.start_offset, [rescue_class(node)])
        end
      end
      best
    end

    # Does `pattern` bind `name`, and to what type? nil = does not bind;
    # [type-or-nil] = binds (a one-element wrapper so "binds, type unknown"
    # stays distinct from "does not bind"). `subject` is the matched
    # expression's node when the pattern applies to it whole, nil once we
    # descend into elements (their values are unknown).
    def pattern_binding(pat, name, subject, document, index, depth)
      case pat
      when Prism::LocalVariableTargetNode
        return unless pat.name == name
        [subject ? type_of(subject, document, index, depth + 1) : nil]
      when Prism::CapturePatternNode
        # `<value pattern> => name`: matching proves the value satisfies the
        # pattern, so the pattern itself types the capture.
        if pat.target.is_a?(Prism::LocalVariableTargetNode) && pat.target.name == name
          [pattern_value_type(pat.value, document, index, depth)]
        else
          pattern_binding(pat.value, name, subject, document, index, depth)
        end
      when Prism::ArrayPatternNode
        pattern_element_binding([*pat.requireds, pat.rest, *pat.posts],
                                name, document, index, depth)
      when Prism::FindPatternNode
        pattern_element_binding([pat.left, *pat.requireds, pat.right],
                                name, document, index, depth)
      when Prism::HashPatternNode
        pattern_element_binding([*pat.elements.map { |e| e.is_a?(Prism::AssocNode) ? e.value : e },
                                 pat.rest], name, document, index, depth)
      when Prism::SplatNode
        # `*rest` in an array/find pattern: binds the leftovers, always an Array.
        t = pattern_binding(pat.expression, name, nil, document, index, depth)
        t && ["Array"]
      when Prism::AssocSplatNode
        # `**rest` in a hash pattern: binds the leftovers, always a Hash.
        t = pattern_binding(pat.value, name, nil, document, index, depth)
        t && ["Hash"]
      when Prism::ImplicitNode
        # `in {name:}` shorthand: binds, but the value's type is unknown.
        pattern_binding(pat.value, name, nil, document, index, depth)
      when Prism::ParenthesesNode
        pattern_binding(pat.body, name, subject, document, index, depth)
      end
      # AlternationPatternNode can't bind (Ruby forbids captures under `|`);
      # pinned patterns don't bind; literal patterns bind nothing.
    end

    def pattern_element_binding(elements, name, document, index, depth)
      elements.each do |el|
        hit = el && pattern_binding(el, name, nil, document, index, depth)
        return hit if hit
      end
      nil
    end

    # The class a capture's VALUE pattern proves about the captured value.
    # `in Integer => n` -> the match IS the type test. Only pattern kinds whose
    # match implies a single class map; everything else -> nil (never guess).
    def pattern_value_type(value, document, index, depth)
      case value
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        # A value constant (HEX = "...") matches by ===/== -> the value's type;
        # otherwise the constant IS the class test (`in Integer => n`).
        infer_constant(value, document, index, depth) || Completion.basic_type(value)
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
        "String" # a regexp pattern matches Strings, not Regexps
      when Prism::SymbolNode  then "Symbol"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode   then "Float"
      when Prism::NilNode     then "NilClass"
      when Prism::TrueNode    then "TrueClass"
      when Prism::FalseNode   then "FalseClass"
      when Prism::RangeNode
        # `in 1..9 => n`: the range CONTAINS the value, so the value types like
        # the endpoints, not like a Range.
        range_element_type(value)
      when Prism::ArrayPatternNode, Prism::FindPatternNode then "Array"
      when Prism::HashPatternNode then "Hash"
      when Prism::AlternationPatternNode
        # `in Integer | String => n`: the match proves n is one of the two --
        # exactly a union. Either side unknown -> nil, as everywhere.
        l = pattern_value_type(value.left, document, index, depth)
        r = pattern_value_type(value.right, document, index, depth)
        UnionType.of([l, r].uniq)
      when Prism::PinnedVariableNode
        type_of(value.variable, document, index, depth + 1)
      when Prism::PinnedExpressionNode
        type_of(value.expression, document, index, depth + 1)
      end
    end

    # A steep-style trailing `#: Type` comment on `line`, as a bare constant
    # path or a union of them (`#: URL::HTTP | URL::Transfer`), or nil. Each
    # alternative must be a plain class name (no generics); one bad segment
    # rejects the whole pin. The union form exists exactly for factories that
    # dispatch to different classes per argument value -- their return can
    # never be inferred, only declared.
    def trailing_annotation(document, line)
      return nil unless document.respond_to?(:ast)
      ast = document.ast
      return nil unless ast.respond_to?(:comments)
      c = ast.comments.find { |x| x.location.start_line == line }
      return nil unless c
      raw = c.location.slice.strip
      return nil unless raw.start_with?("#:")
      # Fixed-delimiter split of our own annotation grammar -- not structured
      # input, same footing as the "::" split below.
      segs = raw.delete_prefix("#:").split("|").map { |s| constant_path_token(s.strip) }
      UnionType.of(segs)
    end

    # `s` when it is a bare constant path (Foo, URL::HTTP), else nil. A hand
    # scan over fixed-delimiter segments — not structured input, no regex.
    def constant_path_token(s)
      return nil if s.empty?
      segs = s.split("::", -1)
      ok = segs.all? do |seg|
        next false if seg.empty? || !seg[0].between?("A", "Z")
        seg.each_char.all? do |ch|
          ch == "_" || ch.between?("A", "Z") || ch.between?("a", "z") || ch.between?("0", "9")
        end
      end
      ok ? s : nil
    end

    # The class a rescue clause proves about its bound variable: the single
    # (uniform) listed exception class, StandardError for a bare rescue, or the
    # UNION of a mixed class list -- `rescue IOError, ArgumentError => e` proves
    # e is exactly one of those. A non-constant entry (splatted list) -> nil.
    def rescue_class(resc)
      return "StandardError" if resc.exceptions.empty?
      names = resc.exceptions.map do |x|
        Completion.basic_type(x) if x.is_a?(Prism::ConstantReadNode) || x.is_a?(Prism::ConstantPathNode)
      end
      UnionType.of(names.uniq)
    end

    # The single type of a LITERAL range's endpoints ((1..9) -> Integer), nil
    # for mixed/non-literal/empty endpoints. Beginless/endless use the one
    # present endpoint.
    def range_element_type(node)
      ts = [node.left, node.right].compact.map do |b|
        case b
        when Prism::IntegerNode then "Integer"
        when Prism::FloatNode   then "Float"
        when Prism::StringNode  then "String"
        end
      end
      return nil if ts.empty? || ts.include?(nil)
      ts.uniq.size == 1 ? ts.first : nil
    end

    # [position, arity] of `name` among a block's positional params, nil when
    # the block doesn't bind it. Covers |a, b|, numbered (_1.._9), and `it`.
    def block_param_position(block, name)
      case (params = block.parameters)
      when Prism::BlockParametersNode
        reqs = params.parameters&.requireds || []
        pos = reqs.index { |p| p.is_a?(Prism::RequiredParameterNode) && p.name == name }
        pos && [pos, reqs.length]
      when Prism::NumberedParametersNode
        s = name.to_s # _1.._9; a hand scan, not a regex (hot path)
        return nil unless s.length == 2 && s.start_with?("_") && s[1].between?("1", "9")
        [s[1].to_i - 1, params.maximum]
      when Prism::ItParametersNode
        name == :it ? [0, 1] : nil
      end
    end

    # The type a call yields to its block at `pos`. Stage 1 first: the called
    # method is a def in this buffer -> the types it actually yields (all yield
    # sites must agree, the infer_return rule). Otherwise the small set of core
    # iterators whose element type the buffer itself proves (literal receivers,
    # Integer/String receivers).
    def yield_param_type(call, pos, arity, document, index, depth)
      return nil if depth > MAX_DEPTH
      defn = resolve_def(call, document, index, depth)
      return yielded_type(defn, pos, document, index, depth) if defn
      core_yield_type(call, pos, arity, document, index, depth)
    end

    def yielded_type(defn, pos, document, index, depth)
      blk = defn.parameters&.block&.name&.to_s
      yields = []
      BlockParams.collect_yields(defn.body, blk, yields)
      return nil if yields.empty?
      types = yields.map { |args| args[pos] && type_of(args[pos], document, index, depth + 1) }.uniq
      # All yield sites proven -> their union (one site stays a bare name).
      UnionType.of(types)
    end

    # Core iteration methods that yield the collection's ELEMENT first. These
    # are mruby core semantics (mrblib/enum/array), not CRuby conventions; the
    # element type still comes from the buffer's own literals -- an opaque
    # receiver stays untyped.
    ELEMENT_YIELDERS = %i[
      each map collect select filter reject find detect find_all flat_map
      sort_by min_by max_by sum take_while drop_while reverse_each delete_if
      keep_if partition group_by count all? any? none? one?
      each_with_index each_with_object each_entry
    ].freeze
    INTEGER_YIELDERS = %i[times upto downto step].freeze
    STRING_YIELDERS  = { each_char: "String", each_line: "String", each_byte: "Integer" }.freeze

    def core_yield_type(call, pos, arity, document, index, depth)
      recv = call.receiver
      return nil unless recv
      meth = call.name
      if meth == :each_with_object && pos == 1
        # The memo object is this call's own argument -- receiver-independent.
        arg = call.arguments&.arguments&.first
        return arg && type_of(arg, document, index, depth + 1)
      end
      lit = literal_receiver(recv, document, index, depth)
      case lit
      when Prism::ArrayNode
        return "Integer" if meth == :each_index && pos.zero?
        return "Integer" if meth == :each_with_index && pos == 1
        uniform_type(lit.elements, document, index, depth) if element_pos?(meth, pos)
      when Prism::RangeNode
        return "Integer" if meth == :each_with_index && pos == 1
        range_element_type(lit) if element_pos?(meth, pos)
      when Prism::HashNode
        hash_yield_type(lit, meth, pos, arity, document, index, depth)
      else
        case type_of(recv, document, index, depth + 1)
        when "Integer"
          "Integer" if INTEGER_YIELDERS.include?(meth) && pos.zero?
        when "String"
          STRING_YIELDERS[meth] if pos.zero?
        end
      end
    end

    def element_pos?(meth, pos) = ELEMENT_YIELDERS.include?(meth) && pos.zero?

    # Hash iteration: |k, v| types from the literal's keys/values; a one-param
    # block gets the [k, v] pair -> Array. Keys and values type independently
    # ({a: 1, b: 2} -> k Symbol, v Integer) and each must be uniform.
    def hash_yield_type(hash, meth, pos, arity, document, index, depth)
      return nil unless hash.elements.all? { |e| e.is_a?(Prism::AssocNode) }
      # These yield the [k, v] PAIR first (plus index/memo), not k and v:
      # h.each_with_index { |pair, i| }.
      if meth == :each_with_index || meth == :each_with_object
        return pos.zero? ? "Array" : (meth == :each_with_index && pos == 1 ? "Integer" : nil)
      end
      case meth
      when :each_key
        uniform_type(hash.elements.map(&:key), document, index, depth) if pos.zero?
      when :each_value
        uniform_type(hash.elements.map(&:value), document, index, depth) if pos.zero?
      when :each_pair, *ELEMENT_YIELDERS
        if arity >= 2
          side = pos.zero? ? hash.elements.map(&:key) : (pos == 1 ? hash.elements.map(&:value) : nil)
          side && uniform_type(side, document, index, depth)
        elsif pos.zero?
          "Array"
        end
      end
    end

    def uniform_type(nodes, document, index, depth)
      return nil if nodes.empty?
      types = nodes.map { |n| type_of(n, document, index, depth + 1) }.uniq
      # Every element proven -> the element type is their union ([1, "a"] yields
      # Integer | String); a single type stays a bare name, unknowns stay nil.
      UnionType.of(types)
    end

    # Follow a receiver back to a literal collection node in this buffer:
    # the literal itself, a local assigned one, or a value constant. nil when
    # the trail leaves the buffer (never guess element types).
    def literal_receiver(node, document, index, depth)
      return nil if depth > MAX_DEPTH
      case node
      when Prism::ArrayNode, Prism::HashNode, Prism::RangeNode then node
      when Prism::ParenthesesNode
        # `(1..9).each` -- a range receiver is necessarily parenthesized.
        b = node.body
        if b.is_a?(Prism::StatementsNode) && b.body.length == 1
          literal_receiver(b.body.first, document, index, depth + 1)
        end
      when Prism::LocalVariableReadNode
        scope = enclosing_scope(document.ast.value, node.location.start_offset)
        w = nearest_write(scope, node.name, node.location.start_offset)
        w && w.value ? literal_receiver(w.value, document, index, depth + 1) : nil
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        short = constant_short_name(node)
        w = short && find_constant_write(document.ast.value, short)
        w && w.value ? literal_receiver(w.value, document, index, depth + 1) : nil
      end
    end

    # ---- method return types (Stage 1 buffer AST, Stage 2 irep via index) ----

    def type_of(node, document, index = nil, depth = 0)
      return nil if node.nil? || depth > MAX_DEPTH
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        # A constant assigned a literal/typed value carries that VALUE's type
        # (HEX_CHARS = "..." -> String). With no resolvable assignment we return
        # nil rather than guessing the name is a class -- never guess. (The
        # class-receiver case, Foo.new / Foo.bar, is handled where it belongs:
        # basic_type / the singleton arm of infer_external_call.)
        infer_constant(node, document, index, depth)
      else
        Completion.basic_type(node) || case node
          when Prism::LocalVariableReadNode
            infer_local(node.name, node.location.start_offset, document, index, depth)
          when Prism::ItLocalVariableReadNode
            # `it` has no name field; it is block param 0 of its ItParameters block.
            infer_local(:it, node.location.start_offset, document, index, depth)
          when Prism::InstanceVariableReadNode
            infer_variable(:ivar, node.name.to_s, node.location.start_offset, document, index, depth)
          when Prism::ClassVariableReadNode
            infer_variable(:cvar, node.name.to_s, node.location.start_offset, document, index, depth)
          when Prism::GlobalVariableReadNode
            infer_variable(:gvar, node.name.to_s, node.location.start_offset, document, index, depth)
          when Prism::CallNode
            infer_call(node, document, index, depth)
          end
      end
    end

    def infer_call(call, document, index = nil, depth = 0)
      return nil if depth > MAX_DEPTH
      return nil unless call.is_a?(Prism::CallNode)
      # Stage 1: a def open in the buffer (always fresh).
      defn = resolve_def(call, document, index, depth)
      return infer_return(defn, document, index, depth + 1) if defn
      # Stage 2: a compiled VM Ruby method, via its irep-derived Entry#return_type.
      infer_external_call(call, document, index, depth) || kernel_cast_type(call)
    end

    # Kernel's capitalized conversion methods have LANGUAGE-defined return
    # types: Array(x) is an Array or it raised. They are C methods, so the
    # irep never types them; this is the fallback that makes `xs = Array(v)`
    # type without clangd. Bare calls with arguments only (a receiver means
    # something else entirely; argument-less `Integer` is a constant, and an
    # explicit `Integer()` without args is not the conversion idiom). A buffer
    # redefinition was already caught by Stage 1 above, and a VM/clangd type,
    # when one exists, was preferred by Stage 2/3.
    KERNEL_CASTS = {
      Array: "Array", String: "String", Integer: "Integer", Float: "Float",
      Hash: "Hash", Rational: "Rational", Complex: "Complex",
    }.freeze
    def kernel_cast_type(call)
      return nil unless call.receiver.nil? && call.arguments&.arguments&.any?
      KERNEL_CASTS[call.name]
    end

    def resolve_def(call, document, index, depth)
      root = document.ast.value
      if call.receiver.nil?
        # A bare call inside a `def self.x` / `class << self` body is `self.x`
        # where self is the MODULE -> resolve to a singleton def (def self.name);
        # an instance-context bare call resolves to an instance def.
        sing = singleton_context?(root, call.location.start_offset)
        def_in(enclosing_class(root, call.location.start_offset), call.name, singleton: sing) ||
          def_in(root, call.name, singleton: sing)
      else
        klass = type_of(call.receiver, document, index, depth + 1)
        scope = klass && class_named(root, klass)
        scope && def_in(scope, call.name)
      end
    end

    # True when offset sits in a singleton method context: inside a `def self.x`
    # (or `def Obj.x`) body, or inside a `class << self` block.
    def singleton_context?(root, offset)
      d = innermost_def(root, offset)
      return true if d && !d.receiver.nil?
      inside = false
      walk(root) do |node|
        next unless node.is_a?(Prism::SingletonClassNode)
        loc = node.location
        inside = true if offset >= loc.start_offset && offset <= loc.end_offset
      end
      inside
    end

    def innermost_def(root, offset)
      best = nil; best_span = nil
      walk(root) do |node|
        next unless node.is_a?(Prism::DefNode)
        loc = node.location
        next unless offset >= loc.start_offset && offset <= loc.end_offset
        span = loc.end_offset - loc.start_offset
        if best_span.nil? || span < best_span
          best = node; best_span = span
        end
      end
      best
    end

    # Stage 2: the method isn't open in the buffer. Resolve its class, look it up
    # in the index, and use the irep-derived return type recorded at populate.
    # A bare class name -> renders exactly like a Stage 1 / ruby-lsp type.
    # A type string -> the concrete class to resolve methods on, or nil. A nilable
    # type (T?) narrows to T: you never dispatch on the nil arm, and real code
    # guards it (`break unless x`). A genuine union (A | B) has no single receiver
    # class -> nil. Bare class names pass through unchanged. Only harvested types
    # carry ? / |; irep/clangd/literal types are already bare, so this is identity
    # for them.
    def concrete_receiver(type)
      return nil unless type
      return nil if type.include?("|")
      type.delete_suffix("?")
    end

    def infer_external_call(call, document, index, depth)
      return nil unless index
      recv = call.receiver
      if recv.nil?
        klass = enclosing_class_name(document.ast.value, call.location.start_offset)
        singleton = singleton_context?(document.ast.value, call.location.start_offset)
      elsif recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)
        # A value constant (HEX_CHARS = "...") is an INSTANCE of its value's
        # type -> instance method. Otherwise the constant names a CLASS and the
        # call is a singleton/class method (Foo.bar).
        vt = infer_constant(recv, document, index, depth + 1)
        if vt
          klass = vt; singleton = false
        else
          klass = Completion.basic_type(recv); singleton = true
        end
      else
        klass = concrete_receiver(type_of(recv, document, index, depth + 1)); singleton = false
      end
      return nil unless klass
      entry = external_method_entry(index, klass, call.name.to_s, singleton)
      return nil unless entry
      # Stage 2.5 first: a hand-written `#:` on the compiled method's def (read
      # from its source file) is the contract and wins over the irep type —
      # the same precedence buffer-def annotations have. Then Stage 1/2's
      # precomputed type (buffer AST / irep), then Stage 3 lazily via clangd.
      rt = (index.respond_to?(:ruby_return_annotation) ? index.ruby_return_annotation(entry) : nil) ||
           entry.return_type ||
           (index.respond_to?(:c_return_type) ? index.c_return_type(entry) : nil)
      # A constructor that builds a fresh instance of its RECEIVER class (IO.for_fd
      # -> IO, File.for_fd -> File) can't be a fixed name in the index — it depends
      # on this call site. clangd reports the RECEIVER sentinel; resolve it to the
      # receiver class we already have (`klass`), the class the method was called on.
      rt == CReturnType::RECEIVER ? klass : rt
    end

    def external_method_entry(index, klass, name, singleton)
      entries =
        if singleton && index.respond_to?(:singleton_methods_for)
          index.singleton_methods_for(klass)
        else
          index.visible_methods(klass)
        end
      entries.find { |e| bare_method_name(e.name) == name }
    end

    # "String#upcase" -> "upcase", "JSON.parse" -> "parse". Flat fixed-delimiter
    # split on a method-entry name (not structured input) -- no regex needed.
    def bare_method_name(full)
      full.to_s.split("#").last.split(".").last
    end

    def def_in(scope, name, singleton: false)
      body_statements(scope).find do |n|
        n.is_a?(Prism::DefNode) && n.name == name &&
          (singleton ? !n.receiver.nil? : n.receiver.nil?)
      end
    end

    def body_statements(scope)
      case scope
      when Prism::ProgramNode then scope.statements.body
      when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        b = scope.body
        b.is_a?(Prism::StatementsNode) ? b.body : (b ? [b] : [])
      else []
      end
    end

    def class_named(root, name)
      want = name.to_s.split("::").last
      best = nil
      best_span = nil
      walk(root) do |node|
        next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        next unless node.name.to_s == want
        span = node.location.end_offset - node.location.start_offset
        if best_span.nil? || span < best_span
          best = node
          best_span = span
        end
      end
      best
    end

    def infer_return(defn, document, index, depth)
      return nil if defn.nil? || depth > MAX_DEPTH
      # A hand-written inline annotation (`#: (...) -> Foo`) is the contract and
      # wins over inferred AST types — same precedence as the `#:` param path.
      ann = return_type_from_annotation(defn, document)
      return ann if ann
      term = terminal_exprs(defn.body).map { |e| e.nil? ? nil : type_of(e, document, index, depth + 1) }
      types = (term + return_types(defn, document, index, depth)).uniq
      # Every terminal proven -> keep the whole set as a union ("A | B") instead
      # of collapsing to unknown; one type stays a bare name (fast path). ANY
      # unknown terminal still poisons the whole return -- unions hold proven
      # members only, never "these, plus something we couldn't type".
      UnionType.of(types)
    end

    def terminal_exprs(node)
      case node
      when nil then []
      when Prism::StatementsNode
        node.body.empty? ? [] : terminal_exprs(node.body.last)
      when Prism::ReturnNode then []
      when Prism::ParenthesesNode then terminal_exprs(node.body)
      when Prism::BeginNode
        t = terminal_exprs(node.statements)
        t += terminal_exprs(node.else_clause.statements) if node.else_clause
        node.rescue_clause ? t + rescue_terminals(node.rescue_clause) : t
      when Prism::IfNode, Prism::UnlessNode
        terminal_exprs(node.statements) + else_terminals(node.subsequent)
      when Prism::CaseNode
        node.conditions.flat_map { |w| terminal_exprs(w.statements) } +
          (node.else_clause ? terminal_exprs(node.else_clause.statements) : [nil])
      else [node]
      end
    end

    def else_terminals(subsequent)
      case subsequent
      when nil then [nil]
      when Prism::ElseNode then terminal_exprs(subsequent.statements)
      else terminal_exprs(subsequent)
      end
    end

    def rescue_terminals(resc)
      t = terminal_exprs(resc.statements)
      resc.subsequent ? t + rescue_terminals(resc.subsequent) : t
    end

    def return_types(defn, document, index, depth)
      rets = []
      collect_returns(defn.body, rets)
      rets.map do |ret|
        args = ret.arguments&.arguments || []
        case args.size
        when 0 then nil
        when 1 then type_of(args.first, document, index, depth + 1)
        else "Array"
        end
      end
    end

    def collect_returns(node, out)
      return unless node.is_a?(Prism::Node)
      return if node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) ||
                node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)
      out << node if node.is_a?(Prism::ReturnNode)
      node.compact_child_nodes.each { |c| collect_returns(c, out) }
    end

    def walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| walk(c, &blk) }
    end

    def pruned_walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each do |c|
        next unless c.is_a?(Prism::Node)
        next if SCOPE_NODES.any? { |k| c.is_a?(k) }
        pruned_walk(c, &blk)
      end
    end
  end
end
