# frozen_string_literal: true

require "prism"
require_relative "locator"
require_relative "completion"
require_relative "scope_resolver"
require_relative "document_highlight"

module MrubyLsp
  # textDocument/signatureHelp. Mirrors ruby-lsp's SignatureHelp listener, but
  # fed by the live VM: ruby-lsp gets multiple signatures from RBS overloads; we
  # get them from the real MRO — every ancestor that defines the method is a
  # distinct definition with its own Method#parameters, listed nearest-first
  # (the nearest is the one that actually resolves, so it is the active one).
  #
  # Shape (LSP SignatureHelp):
  #   { signatures: [{ label: "name(p1, p2)", parameters: [{label:[s,e]}...],
  #                    documentation? }],
  #     activeSignature: Int, activeParameter: Int }
  module SignatureHelp
    module_function

    def response(document, position, index)
      source = document.text
      offset = Locator.position_to_byte_offset(source, position)
      return nil unless offset

      call = enclosing_call(document.ast.value, offset, source.bytesize)
      return nil unless call && call.message # must be a named call

      overloads = resolve_overloads(call, call.name.to_s, document, position, index)
      # ruby-lsp shows no signature help for a method with no parameters.
      overloads = overloads.select { |e| e.params && !e.params.empty? }
      return nil if overloads.empty?
      # Lazy native docs for exactly the shown overloads (memoized). Also swap in
      # the C method's real parameter names (mrb_get_args via clangd) when we can
      # parse them; nil -> keep the aspec-derived signature.
      overloads = overloads.map do |e|
        e = index.enrich(e)
        e.kind == :method ? e.with(params: index.c_signature(e) || e.params) : e
      end

      active_sig = 0 # nearest MRO definition = the one that resolves/runs
      {
        signatures: overloads.map { |e| signature_information(call.name.to_s, e) },
        activeSignature: active_sig,
        activeParameter: active_parameter_index(call, source, offset, overloads[active_sig]),
      }
    end

    # ── locate the innermost paren-call whose argument region holds the cursor ──
    # While typing, the call is often unclosed (no `)`), so its node location may
    # stop before the cursor; for that case the argument region runs to EOF.
    def enclosing_call(root, offset, source_len)
      best = nil
      best_span = nil
      DocumentHighlight.walk(root) do |node|
        next unless node.is_a?(Prism::CallNode)
        op = node.opening_loc
        next unless op # signature help triggers inside `(`
        cl = node.closing_loc
        lo = op.end_offset
        hi = cl ? cl.start_offset : source_len
        next unless offset >= lo && offset <= hi
        span = hi - lo
        if best.nil? || span < best_span
          best = node
          best_span = span
        end
      end
      best
    end

    # Every definition of the method visible from the receiver, nearest-first.
    # Explicit receiver -> public only (private isn't callable with a receiver).
    # Bare call -> enclosing self's public + private (puts/p/print are Kernel
    # private instance methods).
    def resolve_overloads(call, mname, document, position, index)
      receiver = call.receiver
      if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        # Class/module constant receiver IS the class object -> class methods
        # (Foo.bar). singleton_methods_for already walks the superclass spine
        # nearest-first and dedupes by short name.
        klass = Completion.basic_type(receiver)
        return [] unless klass
        index.singleton_methods_for(klass).select { |e| short_name(e.name) == mname }
      elsif receiver
        owner = Completion.receiver_type(receiver, document, index)
        return [] unless owner
        mro_methods(index, owner, mname, include_private: false)
      else
        res = Locator.locate(document.ast.value, document.text, position)
        nesting = res&.nesting || []
        self_owner = nesting.empty? ? "Object" : nesting.join("::")
        mro_methods(index, self_owner, mname, include_private: true)
      end
    end

    def mro_methods(index, receiver, mname, include_private:)
      pool = index.ancestors(receiver).flat_map { |k| index.methods_of(k) }
      pool += index.private_methods_of(receiver) if include_private
      seen = {}
      pool.each_with_object([]) do |e, out|
        next if e.singleton
        next unless short_name(e.name) == mname
        next if seen[e.name] # one per qualified owner#name
        seen[e.name] = true
        out << e
      end
    end

    # ── one SignatureInformation per definition ────────────────────────────────
    def signature_information(mname, entry)
      inner = strip_parens(entry.params.to_s)
      label = "#{mname}(#{inner})"
      info = {
        label: label,
        parameters: parameter_offsets(inner, mname.length + 1),
      }
      doc = entry.doc.to_s
      info[:documentation] = { kind: "markdown", value: doc } unless doc.empty?
      info
    end

    # ParameterInformation labels as [start,end] offsets into the signature label
    # (unambiguous even when two params render identically). Segments never
    # contain a comma — defaults render as the comma-free `...` (the real default
    # expression could contain commas and is deliberately NOT rendered) — so a split
    # is safe and needs no language parsing.
    def parameter_offsets(inner, base)
      return [] if inner.empty?
      pos = base
      inner.split(", ", -1).map do |seg|
        start = pos
        finish = pos + seg.length
        pos = finish + 2 # ", "
        { label: [start, finish] }
      end
    end

    # ── active parameter: ruby-lsp's rule (typed-arg count + trailing comma) ────
    def active_parameter_index(call, source, offset, entry)
      max_idx = [param_count(entry) - 1, 0].max
      args_node = call.arguments
      args = args_node&.arguments || []
      active = [args.length - 1, 0].max
      if args_node
        tail = source.byteslice(args_node.location.end_offset...offset)
        active += 1 if tail&.include?(",")
      end
      active.clamp(0, max_idx)
    end

    def param_count(entry)
      inner = strip_parens(entry.params.to_s)
      inner.empty? ? 0 : inner.split(", ", -1).length
    end

    def strip_parens(params)
      s = params.to_s
      s = s[1..] if s.start_with?("(")
      s = s[0...-1] if s.end_with?(")")
      s
    end

    def short_name(qualified)
      sep = qualified.index("#") || qualified.index(".")
      sep ? qualified[(sep + 1)..] : qualified
    end
  end
end
