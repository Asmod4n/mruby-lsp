# frozen_string_literal: true

require "prism"
require_relative "type_inference"

module MrubyLsp
  # Harvest symbol definitions from an OPEN editor buffer's Prism AST, so that
  # classes/methods that exist only in an unsaved tab are visible to completion/
  # hover/definition before any build sees them.
  #
  # The buffer is processed as an ORDERED sequence of method-table mutations,
  # because Ruby is dynamic and order matters (def x; undef x; def x nets to
  # present). We model exactly the dynamic forms mruby actually supports, with
  # mruby's observed semantics (not CRuby's) — verified by probing the live VM:
  #
  #   def / def self.x        -> add (instance / singleton), current visibility
  #   private/protected/public -> visibility scope (bare, :sym args, inline def)
  #   attr_reader/writer/accessor/attr -> generated accessors (r / w= / a + a=)
  #   alias / alias_method    -> new name, snapshot of target's current signature
  #   define_method(:literal) -> add, PUBLIC regardless of scope (mruby quirk)
  #   module_function :name   -> add a public singleton copy (mruby: explicit
  #                              args only; bare form is inert; instance stays public)
  #   undef / undef_method    -> tombstone (blocks inherited) -> Entry kind :undef
  #   remove_method           -> drop own copy only             -> Entry kind :remove
  #   include / prepend       -> carried on the class Entry's mixins (ancestry)
  #
  # No eval, structural only: dynamic forms with non-literal (runtime-computed)
  # names are undecidable from an unrun buffer and are skipped — there the live
  # VM after build remains the source of truth.
  module BufferHarvester
    module_function

    DELETE_VERBS = { undef_method: :undef, remove_method: :remove }.freeze
    ATTR_VERBS   = %i[attr_reader attr_writer attr_accessor attr].freeze
    VIS_VERBS    = %i[public private protected].freeze

    def harvest(uri, ast_value, source, index = nil)
      parsed   = Prism.parse(source)
      comments = comment_lines(parsed)
      out = []
      stmts = statements_of(ast_value)
      # Lightweight document for Stage-1 return-type inference over this buffer's
      # own AST. tdoc.ast carries .value (infer_return) AND .comments (inline
      # annotation lookup via TypeInference.annotation_line_above) -- the real
      # Document.ast is a Prism::ParseResult, so it answers both; tdoc must too.
      # idx = nil here: buffer return types are pure AST, no VM coupling.
      tdoc = Struct.new(:ast).new(Struct.new(:value, :comments).new(ast_value, parsed.comments))
      process(stmts, [], uri, comments, out, tdoc: tdoc, idx: index)
      out
    end

    # { "Outer::Class" => { "@x" => [type names] } } for every native_ext_type
    # declaration in this open buffer. The server feeds it to the index's buffer
    # ivar layer so `@x.` typing sees a just-typed declaration (buffer-wins over
    # the compiled VM). Pure AST walk; union types are kept (the index decides
    # union -> nil). Separate from harvest() so harvest's array return is unchanged.
    def ivar_schemas(ast_value)
      out = {}
      collect_ivar_schemas(statements_of(ast_value), [], out)
      out
    end

    def collect_ivar_schemas(stmts, nesting, out)
      stmts.each do |stmt|
        next unless stmt.is_a?(Prism::ClassNode) || stmt.is_a?(Prism::ModuleNode)
        nm = const_name(stmt.constant_path)
        next unless nm
        inner = statements_of(stmt)
        fq = (nesting + [nm]).join("::")
        inner.each do |s|
          d = native_ext_decl(s)
          (out[fq] ||= {})[d[0]] = d[1] if d
        end
        collect_ivar_schemas(inner, nesting + [nm], out)
      end
    end

    # Process a statement list in SOURCE ORDER, tracking the current default
    # visibility for the enclosing class/module body. sclass: true means we're
    # inside a `class << self` (or `class << Const`) body, so every emitted
    # method-table op targets the SINGLETON side.
    def process(stmts, nesting, uri, comments, out, sclass: false, tdoc: nil, idx: nil)
      vis = { v: :public } # mutable cell so dispatch helpers can change it
      # native_ext_type declarations in THIS body, so attr_* accessors generated
      # below inherit the declared ivar type (attr_reader :x over
      # `native_ext_type :@x, T` -> reader returns T). Single concrete only;
      # union -> omitted (never guessed).
      ivar_types = body_ivar_types(stmts)
      stmts.each do |stmt|
        case stmt
        when Prism::ClassNode, Prism::ModuleNode
          emit_namespace(stmt, nesting, uri, comments, out, tdoc: tdoc, idx: idx)
        when Prism::SingletonClassNode
          # `class << self` -> the enclosing class's singleton side, fresh
          # public visibility scope (matches Ruby). `class << Foo` -> Foo's
          # singleton side. Any other expression (class << obj) is a runtime
          # value -> undecidable without eval -> skip.
          target =
            case stmt.expression
            when Prism::SelfNode then nesting
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              n = const_name(stmt.expression)
              n ? n.split("::") : nil
            end
          process(statements_of(stmt), target, uri, comments, out, sclass: true, tdoc: tdoc, idx: idx) if target
        when Prism::DefNode
          emit_def(stmt, nesting, uri, comments, out, vis[:v], sclass: sclass, tdoc: tdoc, idx: idx)
        when Prism::CallNode
          dispatch_call(stmt, nesting, uri, comments, out, vis, sclass: sclass, ivar_types: ivar_types, tdoc: tdoc, idx: idx)
        when Prism::AliasMethodNode
          emit_alias(stmt, nesting, uri, out, vis[:v], sclass: sclass)
        when Prism::UndefNode
          emit_undef(stmt, nesting, uri, out, sclass: sclass)
        else
          descend(stmt, nesting, uri, comments, out, tdoc: tdoc, idx: idx)
        end
      end
    end

    def emit_namespace(node, nesting, uri, comments, out, tdoc: nil, idx: nil)
      name = const_name(node.constant_path)
      return unless name
      fq = (nesting + [name]).join("::")
      sup = (node.is_a?(Prism::ClassNode) && node.superclass) ? const_name(node.superclass) : nil
      out << Entry.new(
        name: fq,
        owner: nesting.join("::").then { |s| s.empty? ? "Object" : s },
        kind: node.is_a?(Prism::ModuleNode) ? :module : :class,
        uri: uri, line: node.location.start_line, params: nil,
        native: false, singleton: false,
        doc: doc_above(comments, node.location.start_line),
        range: full_range(node), name_range: loc_range(node.constant_path.location),
        superclass: sup, mixins: class_mixins(node),
      )
      process(statements_of(node), nesting + [name], uri, comments, out, tdoc: tdoc, idx: idx)
    end

    def emit_def(node, nesting, uri, comments, out, visibility, forced_visibility: nil, sclass: false, tdoc: nil, idx: nil)
      owner = owner_of(nesting)
      singleton = sclass || !node.receiver.nil?
      # Stage 1: irep-free return type straight from this buffer's AST, so an
      # edit in ANY open tab is reflected immediately (the index buffer overlay
      # returns this twin; compiled-only methods keep their irep type). index nil
      # -> no VM recursion here; defaults to nil when undecidable.
      rt = tdoc ? TypeInference.infer_return(node, tdoc, idx, 0) : nil
      out << method_entry(
        owner: owner, mname: node.name.to_s, singleton: singleton,
        params: render_params(node), uri: uri, line: node.location.start_line,
        doc: doc_above(comments, node.location.start_line),
        range: full_range(node), name_range: loc_range(node.name_loc),
        visibility: forced_visibility || visibility, return_type: rt,
      )
      # ivars/cvars/globals are commonly written inside method bodies.
      node.compact_child_nodes.each { |c| descend(c, nesting, uri, comments, out, tdoc: tdoc, idx: idx) }
    end

    def dispatch_call(call, nesting, uri, comments, out, vis, sclass: false, ivar_types: {}, tdoc: nil, idx: nil)
      return descend(call, nesting, uri, comments, out, tdoc: tdoc, idx: idx) unless call.receiver.nil?
      sym = call.name
      args = call_args(call)

      if VIS_VERBS.include?(sym)
        apply_visibility(sym, call, args, nesting, uri, comments, out, vis, sclass: sclass)
      elsif ATTR_VERBS.include?(sym)
        emit_attrs(sym, args, nesting, uri, out, vis[:v], sclass: sclass, ivar_types: ivar_types, idx: idx)
      elsif sym == :alias_method
        names = args.filter_map { |a| literal_name(a) }
        emit_alias_pair(names[0], names[1], nesting, uri, out, vis[:v], call.location, sclass: sclass) if names.size >= 2
      elsif DELETE_VERBS.key?(sym)
        kind = DELETE_VERBS[sym]
        args.each { |a| (nm = literal_name(a)) && emit_delete(kind, owner_of(nesting), nm, uri, call.location, out, sclass: sclass) }
      elsif sym == :define_method
        nm = literal_name(args[0])
        # mruby: define_method'd methods are PUBLIC regardless of surrounding scope.
        emit_synth(owner_of(nesting), nm, params_from_block(call), uri, call.location, out, :public, singleton: sclass) if nm
      elsif sym == :module_function
        # mruby: explicit-arg form adds a public singleton copy; bare form is inert.
        args.each do |a|
          nm = literal_name(a)
          emit_synth(owner_of(nesting), nm, signature_for(owner_of(nesting), nm, out), uri, call.location, out, :public, singleton: true) if nm
        end
      else
        descend(call, nesting, uri, comments, out, tdoc: tdoc, idx: idx)
      end
    end

    # public/private/protected: bare -> set default; :sym args -> retro-set those
    # already-emitted methods; inline `private def foo` -> emit the def with that
    # visibility.
    def apply_visibility(verb, _call, args, nesting, uri, comments, out, vis, sclass: false)
      if args.empty?
        vis[:v] = verb
        return
      end
      owner = owner_of(nesting)
      args.each do |a|
        case a
        when Prism::DefNode
          emit_def(a, nesting, uri, comments, out, vis[:v], forced_visibility: verb, sclass: sclass)
        else
          nm = literal_name(a)
          retro_visibility(out, owner, nm, verb, sclass: sclass) if nm
        end
      end
    end

    def emit_attrs(verb, args, nesting, uri, out, visibility, sclass: false, ivar_types: {}, idx: nil)
      owner = owner_of(nesting)
      args.each do |a|
        nm = literal_name(a)
        next unless nm
        # The accessor reads/writes @nm, so its type IS @nm's type: a same-body
        # native_ext_type declaration (buffer-wins) or the VM index's schema.
        t = ivar_types["@#{nm}"]
        t ||= idx.ivar_type(owner, "@#{nm}") if t.nil? && idx.respond_to?(:ivar_type)
        if verb == :attr_reader || verb == :attr_accessor || verb == :attr
          emit_synth(owner, nm, "()", uri, a.location, out, visibility, singleton: sclass, return_type: t)
        end
        if verb == :attr_writer || verb == :attr_accessor
          # `x = v` evaluates to v, which the contract says is @nm's type.
          emit_synth(owner, "#{nm}=", "(value)", uri, a.location, out, visibility, singleton: sclass, return_type: t)
        end
      end
    end

    # `Foo = Struct.new(:a, :b)` or `Foo = Data.define(:a, :b)` -> harvest Foo as
    # a class with one reader per member (and a writer per member for Struct,
    # which is mutable; Data is read-only). A trailing `do ... end` body defines
    # further methods INTO the class. Returns true if it handled the node (so the
    # caller skips the plain-constant entry), false otherwise.
    # A constant assigned a class/module DEFINITION on its RHS:
    #   Foo = Struct.new(:a, :b)        -> class Foo < Struct, readers + writers
    #   Foo = Data.define(:a, :b)       -> class Foo < Data,   readers only
    #   Foo = Class.new(Base) do … end  -> class Foo < Base (Object if omitted)
    #   Mod = Module.new do … end       -> module Mod
    # The constant write may be `=`, `||=`, or `&&=` (node responds to value/
    # name/name_loc the same way). A trailing `do … end` body's defs and
    # include/prepend/extend belong to the new namespace. Returns true if handled.
    def emit_const_definition(node, nesting, uri, comments, out, tdoc: nil, idx: nil)
      call = node.value
      return false unless call.is_a?(Prism::CallNode) && call.receiver
      base = const_name(call.receiver)
      kind =
        if    base == "Struct" && call.name == :new    then :struct
        elsif base == "Data"   && call.name == :define  then :data
        elsif base == "Class"  && call.name == :new    then :class
        elsif base == "Module" && call.name == :new    then :module
        end
      return false unless kind

      name = node.name.to_s
      fq = (nesting + [name]).join("::")
      blk = call.block
      sup =
        case kind
        when :struct then "Struct"
        when :data   then "Data"
        when :class  then const_name(call_args(call).first) || "Object" # Class.new(Base)
        end
      out << Entry.new(
        name: fq, owner: owner_of(nesting),
        kind: (kind == :module ? :module : :class), uri: uri,
        line: node.location.start_line, params: nil, native: false, singleton: false,
        doc: doc_above(comments, node.location.start_line),
        range: full_range(node), name_range: loc_range(node.name_loc),
        superclass: sup, mixins: (blk ? class_mixins(blk) : []),
      )

      # Struct/Data members are SYMBOL args (a leading String in
      # `Struct.new("Name", :a)` names the class — not a member — so only
      # symbols count). Reader per member; writer too for the mutable Struct.
      if kind == :struct || kind == :data
        call_args(call).each do |arg|
          next unless arg.is_a?(Prism::SymbolNode)
          m = literal_name(arg)
          next unless m
          emit_synth(fq, m, "()", uri, arg.location, out, :public)
          emit_synth(fq, "#{m}=", "(value)", uri, arg.location, out, :public) if kind == :struct
        end
      end

      # `… do def total; …; end end`: defs in the block body belong to the class.
      process(statements_of(blk), nesting + [name], uri, comments, out, tdoc: tdoc, idx: idx) if blk
      true
    end

    # Constant targets of a multiple assignment (`A, B = …`, incl. nested
    # `(C, D)` groups), flattened. Non-constant targets (locals, ivars, splats)
    # are left to their own harvesting.
    def multi_constant_targets(node)
      targets = []
      collect = lambda do |n|
        return unless n
        case n
        when Prism::ConstantTargetNode then targets << n
        when Prism::MultiTargetNode
          (n.lefts + (n.rest ? [n.rest] : []) + n.rights).each { |t| collect.call(t) }
        end
      end
      (node.lefts + (node.rest ? [node.rest] : []) + node.rights).each { |t| collect.call(t) }
      targets
    end

    # native_ext_type(:@x, T1, T2, ...) -> ["@x", ["T1","T2"]] | nil. Reads the
    # declaration structurally; runtime-computed names are skipped (no eval).
    def native_ext_decl(call)
      return nil unless call.is_a?(Prism::CallNode) && call.receiver.nil? && call.name == :native_ext_type
      args = call_args(call)
      ivar = symbol_text(args[0])
      return nil unless ivar && ivar.start_with?("@")
      types = (args[1..] || []).filter_map { |a| const_name(a) }
      types.empty? ? nil : [ivar, types]
    end

    # { "@x" => "T" } for a body's SINGLE-type native_ext_type decls (union is
    # omitted -> never guessed). Drives attr_* accessor return types.
    def body_ivar_types(stmts)
      m = {}
      stmts.each do |s|
        d = native_ext_decl(s)
        next unless d
        ivar, types = d
        m[ivar] = types.first if types.size == 1
      end
      m
    end

    def emit_alias(node, nesting, uri, out, visibility, sclass: false)
      new_name = symbol_text(node.new_name)
      old_name = symbol_text(node.old_name)
      emit_alias_pair(new_name, old_name, nesting, uri, out, visibility, node.location, sclass: sclass)
    end

    def emit_alias_pair(new_name, old_name, nesting, uri, out, visibility, loc, sclass: false)
      return unless new_name && old_name
      owner = owner_of(nesting)
      out << method_entry(
        owner: owner, mname: new_name, singleton: sclass,
        params: signature_for(owner, old_name, out, singleton: sclass), uri: uri,
        line: loc.start_line, doc: nil, range: loc_range(loc),
        name_range: loc_range(loc), visibility: visibility,
      )
    end

    def emit_undef(node, nesting, uri, out, sclass: false)
      owner = owner_of(nesting)
      node.names.each do |n|
        nm = symbol_text(n)
        emit_delete(:undef, owner, nm, uri, node.location, out, sclass: sclass) if nm
      end
    end

    def emit_delete(kind, owner, mname, uri, loc, out, sclass: false)
      out << Entry.new(
        name: "#{owner}#{sclass ? '.' : '#'}#{mname}", owner: owner, kind: kind,
        uri: uri, line: loc.start_line, params: nil, native: false,
        singleton: sclass, doc: nil, range: loc_range(loc), name_range: loc_range(loc),
      )
    end

    def emit_synth(owner, mname, params, uri, loc, out, visibility, singleton: false, return_type: nil)
      out << method_entry(
        owner: owner, mname: mname, singleton: singleton, params: params,
        uri: uri, line: loc.start_line, doc: nil,
        range: loc_range(loc), name_range: loc_range(loc), visibility: visibility,
        return_type: return_type,
      )
    end

    def method_entry(owner:, mname:, singleton:, params:, uri:, line:, doc:, range:, name_range:, visibility:, return_type: nil)
      sep = singleton ? "." : "#"
      Entry.new(
        name: "#{owner}#{sep}#{mname}", owner: owner, kind: :method,
        uri: uri, line: line, params: params, native: false,
        singleton: singleton, doc: doc, range: range, name_range: name_range,
        visibility: visibility, return_type: return_type,
      )
    end

    # Replace an already-emitted method entry's visibility (private :sym after def).
    def retro_visibility(out, owner, mname, verb, sclass: false)
      key = "#{owner}#{sclass ? '.' : '#'}#{mname}"
      idx = out.rindex { |e| e.kind == :method && e.name == key && e.singleton == sclass }
      out[idx] = out[idx].with(visibility: verb) if idx
    end

    # Walk non-namespace nodes for nested definitions AND ivar/cvar/gvar/constant
    # writes. Definitions inside blocks/conditionals (e.g. `assert do class Foo;
    # end end`, `class Bar; end if cond`) still define into the LEXICALLY
    # enclosing namespace in Ruby, so harvest them exactly like top-level ones —
    # otherwise hover/F12/completion can't see a class declared inside a `do`
    # block (common in test suites). The dedicated emitters process each
    # definition's own body, so we `return` instead of falling through to the
    # generic child-walk (which would double-process it).
    def descend(node, nesting, uri, comments, out, tdoc: nil, idx: nil)
      return unless node.is_a?(Prism::Node)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        emit_namespace(node, nesting, uri, comments, out, tdoc: tdoc, idx: idx)
        return
      when Prism::SingletonClassNode
        target =
          case node.expression
          when Prism::SelfNode then nesting
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            (n = const_name(node.expression)) ? n.split("::") : nil
          end
        process(statements_of(node), target, uri, comments, out, sclass: true, tdoc: tdoc, idx: idx) if target
        return
      when Prism::DefNode
        # A def opened inside a block gets a fresh, public visibility scope.
        emit_def(node, nesting, uri, comments, out, :public, tdoc: tdoc, idx: idx)
        return
      when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        # `Foo = Struct.new(...)` / `Data.define(...)` / `Class.new(Base)` /
        # `Module.new` define a real class/module named Foo (not a plain
        # constant): an instance responds to its methods, so harvest it as a
        # namespace so `f.` completes. Also covers `Foo ||=`/`&&=` forms. Editor
        # only — none of this is compiled into the VM. If it's not a definition,
        # fall back to a plain constant entry.
        if emit_const_definition(node, nesting, uri, comments, out, tdoc: tdoc, idx: idx)
          return
        end
        owner = owner_of(nesting)
        fq = (nesting + [node.name.to_s]).join("::")
        out << Entry.new(name: fq, owner: owner, kind: :constant, uri: uri,
                         line: node.location.start_line, params: nil, native: false,
                         singleton: false, doc: doc_above(comments, node.location.start_line),
                         range: full_range(node), name_range: loc_range(node.name_loc))
      when Prism::MultiWriteNode
        # `A, B = 1, 2` / `A, (B, C) = …`: each constant target is a constant.
        multi_constant_targets(node).each do |t|
          out << Entry.new(name: (nesting + [t.name.to_s]).join("::"), owner: owner_of(nesting),
                           kind: :constant, uri: uri, line: t.location.start_line, params: nil,
                           native: false, singleton: false, doc: nil,
                           range: full_range(t), name_range: full_range(t))
        end
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableTargetNode,
           Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::InstanceVariableOperatorWriteNode,
           Prism::ClassVariableWriteNode, Prism::ClassVariableTargetNode,
           Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
           Prism::ClassVariableOperatorWriteNode,
           Prism::GlobalVariableWriteNode, Prism::GlobalVariableTargetNode,
           Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
           Prism::GlobalVariableOperatorWriteNode
        # Every write FORM defines the variable, not just `=`: `@x ||= 0` (the
        # ubiquitous memoization idiom), `@@n &&= v`, `@x += 1`, `$g ||= …`. All
        # carry .name / .name_loc; classify by the node family.
        cls = node.class.name.to_s
        kind = if cls.include?("InstanceVariable") then :ivar
               elsif cls.include?("ClassVariable") then :cvar
               else :gvar
               end
        out << Entry.new(name: node.name.to_s, owner: owner_of(nesting), kind: kind,
                         uri: uri, line: node.location.start_line, params: nil,
                         native: false, singleton: false, doc: nil,
                         range: full_range(node), name_range: loc_range(name_loc_of(node)))
      end
      node.compact_child_nodes.each { |c| descend(c, nesting, uri, comments, out, tdoc: tdoc, idx: idx) }
    end

    # ── helpers ──────────────────────────────────────────────────────────────

    def owner_of(nesting)
      nesting.join("::").then { |s| s.empty? ? "Object" : s }
    end

    def statements_of(node)
      body =
        if node.is_a?(Prism::ProgramNode) then node.statements
        elsif node.respond_to?(:body) then node.body
        else nil
        end
      body.is_a?(Prism::StatementsNode) ? body.body : []
    end

    def call_args(call)
      call.arguments&.arguments || []
    end

    # A literal symbol/string argument's text, else nil (runtime-computed names
    # are undecidable without eval — skip them).
    def literal_name(node)
      case node
      when Prism::SymbolNode then node.respond_to?(:unescaped) ? node.unescaped : node.value
      when Prism::StringNode then node.respond_to?(:unescaped) ? node.unescaped : node.content
      end
    end

    def symbol_text(node)
      return nil unless node
      return literal_name(node) if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      # bare `alias new old` / `undef x` give SymbolNode in Prism; guard anything else.
      node.respond_to?(:unescaped) ? node.unescaped : nil
    end

    # Snapshot the signature of an existing own method (alias/module_function copy
    # the target's current signature). Falls back to a generic arity.
    def signature_for(owner, mname, out, singleton: false)
      return "()" unless mname
      key = "#{owner}#{singleton ? '.' : '#'}#{mname}"
      e = out.reverse.find { |x| x.kind == :method && x.name == key }
      e ? e.params : "(...)"
    end

    def params_from_block(call)
      blk = call.block
      return "(...)" unless blk.respond_to?(:parameters) && blk.parameters
      p = blk.parameters
      p.respond_to?(:parameters) && p.parameters ? render_params_from(p.parameters) : "()"
    end

    def class_mixins(node)
      stmts = statements_of(node)
      stmts.flat_map do |stmt|
        next [] unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?
        kind = case stmt.name when :include then :include when :prepend then :prepend when :extend then :extend end
        next [] unless kind
        call_args(stmt).filter_map do |arg|
          if kind == :extend && arg.is_a?(Prism::SelfNode)
            [:extend, :__self__] # `extend self`: module's instance methods become its own singletons
          elsif (nm = const_name(arg))
            [kind, nm]
          end
        end
      end
    end

    def const_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = node.respond_to?(:parent) && node.parent ? const_name(node.parent) : nil
        parent ? "#{parent}::#{node.name}" : node.name.to_s
      end
    end

    def full_range(node) = loc_range(node.location)

    def loc_range(loc)
      return nil unless loc
      { start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) } }
    end

    def name_loc_of(node)
      (node.respond_to?(:name_loc) && node.name_loc) ? node.name_loc : node.location
    end

    def render_params(def_node)
      render_params_from(def_node.parameters)
    end

    def render_params_from(params)
      return "()" if params.nil?
      parts = []
      params.requireds.each { |p| parts << p.name.to_s } if params.respond_to?(:requireds)
      params.optionals.each { |p| parts << "#{p.name} = ..." } if params.respond_to?(:optionals)
      if params.respond_to?(:rest) && params.rest
        nm = params.rest.respond_to?(:name) && params.rest.name ? params.rest.name : ""
        parts << "*#{nm}"
      end
      if params.respond_to?(:keywords)
        params.keywords.each { |k| parts << (k.respond_to?(:value) && k.value ? "#{k.name}: ..." : "#{k.name}:") }
      end
      if params.respond_to?(:keyword_rest) && params.keyword_rest
        nm = params.keyword_rest.respond_to?(:name) && params.keyword_rest.name ? params.keyword_rest.name : ""
        parts << "**#{nm}"
      end
      if params.respond_to?(:block) && params.block
        nm = params.block.respond_to?(:name) && params.block.name ? params.block.name : "block"
        parts << "&#{nm}"
      end
      "(#{parts.join(', ')})"
    end

    def comment_lines(parsed)
      map = {}
      parsed.comments.each { |c| map[c.location.start_line] = c.slice.sub(/\A#\s?/, "") }
      map
    end

    def doc_above(comments, def_line)
      lines = []
      line = def_line - 1
      while comments.key?(line)
        lines.unshift(comments[line]); line -= 1
      end
      return nil if lines.empty?
      text = lines.join("\n").strip
      text.empty? ? nil : text
    end
  end
end
