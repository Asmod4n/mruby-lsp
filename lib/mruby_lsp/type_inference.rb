# frozen_string_literal: true

require "prism"
require_relative "inline_type"

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
      return type_of(write.value, document, index, depth + 1) if write && write.value

      # No assignment reaches this use, so `name` may be a method parameter. A
      # param has no LocalVariableWriteNode; its type, if any, comes from the
      # enclosing def's inline annotation (#: (...) -> ...). A later reassignment
      # would have been found above and rightly wins over the annotation.
      param_type_from_annotation(name, usage_offset, document)
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
      infer_external_call(call, document, index, depth)
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
      # Stage 1/2: a precomputed type (buffer AST / irep). Stage 3: a C method
      # with no precomputed type -> resolve lazily via clangd (memoized).
      entry.return_type ||
        (index.respond_to?(:c_return_type) ? index.c_return_type(entry) : nil)
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
      return nil if types.empty?
      types.size == 1 ? types.first : nil
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
