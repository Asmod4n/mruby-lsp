# frozen_string_literal: true

require_relative "scope_resolver"
require_relative "locator"
require_relative "completion"
require_relative "type_inference"

module MrubyLsp
  # T4.2 — hover. Mirrors ruby-lsp's exact markdown contract:
  #
  #   ```ruby
  #   signature
  #   ```
  #   **Definitions**: [file](uri#Lline)
  #
  # Fed by the live VM index (no RBS, no doc prose — structure stays identical,
  # content as rich as the VM allows). Reuses Locator and Completion helpers.
  module Hover
    module_function

    def response(document, position, index)
      result = Locator.locate(document.ast.value, document.text, position)
      return nil unless result&.node

      # Heredoc construct hover (no index needed) — mirrors ruby-lsp's
      # generate_heredoc_hover: a canned explanation keyed on the heredoc type.
      heredoc = heredoc_message(result.node)
      return { contents: { kind: "markdown", value: heredoc } } if heredoc

      entries = resolve_entries(result.node, index, result.nesting || [], document, result)
      return nil if entries.empty?
      # Lazy native locations/docs: resolve addr2line+RDoc for exactly these
      # entries, now that a user actually asked. Memoized in the index.
      entries = entries.map { |e| index.enrich(e) }

      # ruby-lsp lists EVERY definition of a reopened class / reassigned constant
      # (all Definition links + all comments). resolve_entries gives the collapsed
      # winner; expand it to the full ordered set for constants/classes/modules.
      # ruby-lsp lists EVERY entry of the resolved target -- reopened classes,
      # reassigned constants, AND reopened methods on the nearest owner
      # (resolve_method returns all entries of the first defining ancestor).
      all = index.definitions(entries.first.name)
      entries = all.map { |e| index.enrich(e) } unless all.empty?

      # Override/shadow chain: only owners that DEFINE the method, minus the
      # one already displayed, plus a same-class VM twin a buffer def shadows.
      overrides = override_chain(entries, method_ancestry(result, index, document), index)

      # Ruby docs are already on the entry (Prism, at index time). C methods have
      # none until now: fetch the comment from clangd lazily, only for the entries
      # actually being shown. nil (no clangd / no comment) leaves doc empty.
      # CTypeResolver#doc returns the comment ALONE (clangd completion docs), as
      # plaintext with real newlines. Fence it as a code block so the lines
      # render verbatim (a single \n is not a markdown break). The info string
      # `code` is REQUIRED: a bare ``` fence makes VSCode\'s hover renderer fall
      # back to the editor language (Ruby), syntax-coloring the comment and
      # collapsing it; `code` forces a plain, uncolored, line-preserving block.
      entries = entries.map do |e|
        # Prefer the C method's REAL parameter names (parsed from mrb_get_args
        # via clangd) over the aspec's argN placeholders. nil for Ruby methods or
        # an unparseable call -> keep the existing signature.
        e = e.with(params: index.c_signature(e) || e.params) if e.kind == :method
        next e unless e.doc.to_s.empty?
        cdoc = index.c_doc(e)
        cdoc ? e.with(doc: "```code\n#{cdoc}\n```") : e
      end
      contents = render(entries, overrides)
      return nil unless contents

      { contents: { kind: "markdown", value: contents } }
    end

    # The receiver's full MRO for method targets (incl. super: the enclosing
    # method's chain). nil for non-method targets / unknown receivers.
    def method_ancestry(result, index, document)
      node = result.node
      nesting = result.nesting || []
      case node
      when Prism::SuperNode, Prism::ForwardingSuperNode
        def_node = result.def_node
        return nil unless def_node
        owner = nesting.empty? ? "Object" : nesting.join("::")
        index.method_chain(owner, def_node.name.to_s,
                           singleton: result.sclass || !def_node.receiver.nil?)
      when Prism::CallNode
        meth = node.name.to_s
        recv = node.receiver
        if recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)
          klass = Completion.basic_type(recv)
          klass = ScopeResolver.constant(klass, nesting, index).first&.name || klass if klass
          klass && index.method_chain(klass, meth, singleton: true)
        elsif recv
          owner = Completion.receiver_type(recv, document, index)
          owner && index.method_chain(owner, meth)
        elsif !nesting.empty?
          index.method_chain(nesting.join("::"), meth)
        end
      when Prism::DefNode
        owner = nesting.empty? ? "Object" : nesting.join("::")
        index.method_chain(owner, node.name.to_s, singleton: !node.receiver.nil?)
      end
    end

    def override_chain(entries, chain, index)
      shown = entries.first.name
      list = (chain || []).filter_map { |owner, e| [owner, e] if e && e.name != shown }
      vm_twin = index.shadowed(shown).first
      list.unshift([shown.split(/[#.]/).first, vm_twin]) if vm_twin
      list
    end

    HEREDOC_NODES = [
      Prism::StringNode, Prism::InterpolatedStringNode,
      Prism::XStringNode, Prism::InterpolatedXStringNode,
    ].freeze

    # If node is a heredoc, return ruby-lsp's explanatory hover text, else nil.
    # The opener (`<<HEREDOC`, `<<-DASH`, `<<~SQ`, optionally quoted) is parsed
    # structurally from Prism's opening_loc slice — no language regex.
    def heredoc_message(node)
      return nil unless HEREDOC_NODES.include?(node.class)
      return nil unless node.respond_to?(:heredoc?) && node.heredoc?
      opener = node.opening_loc&.slice
      return nil unless opener && opener.start_with?("<<")
      rest = opener[2..] # after "<<"
      squiggly = rest.start_with?("~")
      rest = rest[1..] if rest.start_with?("~", "-")
      delim = rest.delete("'\"`") # strip optional quotes around the delimiter
      return nil if delim.empty?
      if squiggly
        "This is a squiggly heredoc definition using the `#{delim}` delimiter. " \
          "Indentation will be ignored in the resulting string."
      else
        "This is a heredoc definition using the `#{delim}` delimiter. " \
          "Indentation will be considered part of the string."
      end
    end

    def resolve_entries(node, index, nesting = [], document = nil, result = nil)
      case node
      when Prism::SuperNode, Prism::ForwardingSuperNode
        # ruby-lsp: hovering `super` shows the PARENT implementation of the
        # surrounding method (resolve_method inherited_only: skip the current
        # class, take the first defining ancestor after it).
        def_node = result&.def_node
        return [] unless def_node
        owner = nesting.empty? ? "Object" : nesting.join("::")
        singleton = result.sclass || !def_node.receiver.nil?
        chain = index.method_chain(owner, def_node.name.to_s, singleton: singleton)
        parent = chain.drop_while { |o, _| o == owner }.find { |_, e| e }
        parent ? index.definitions(parent[1].name) : []
      when Prism::ConstantReadNode, Prism::ConstantWriteNode,
           Prism::ConstantOperatorWriteNode,
           Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
        resolve_constant(node.name.to_s, nesting, index)
      when Prism::ConstantPathNode
        index.resolve(Completion.constant_path_name(node))
      when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
           Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode,
           Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
           Prism::ClassVariableReadNode, Prism::ClassVariableWriteNode,
           Prism::ClassVariableOperatorWriteNode, Prism::ClassVariableTargetNode,
           Prism::ClassVariableOrWriteNode, Prism::ClassVariableAndWriteNode,
           Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode,
           Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableTargetNode,
           Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode
        # @ivar / @@cvar / $global — resolve by bare name against the index.
        index.resolve(node.name.to_s)
      when Prism::LocalVariableReadNode, Prism::LocalVariableTargetNode,
           Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableWriteNode,
           Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
        # A local variable: hover shows its INFERRED type's class (and where that
        # class is defined), the same funnel completion uses for `payload.`.
        # `payload = {…}` -> Hash; an annotated parameter -> its annotated class.
        # On the ASSIGNMENT itself infer straight from the RHS (nearest_write
        # requires the write to END at/before the cursor, so it can't see its own
        # assignment); elsewhere walk back to the reaching write / param
        # annotation. nil when nothing can be inferred -> no hover. Resolve through
        # the cursor's nesting so a user-defined (possibly nested) type resolves.
        type =
          if document && node.is_a?(Prism::LocalVariableWriteNode) && node.value
            TypeInference.type_of(node.value, document, index, 0)
          elsif document
            TypeInference.infer_local(node.name, node.location.start_offset, document, index)
          end
        type ? resolve_constant(type, nesting, index) : []
      when Prism::CallNode
        meth = node.name.to_s
        if node.receiver
          # Constant receiver -> the class object's singleton methods; instance
          # receiver -> instance methods; unknown type -> nothing (don't guess
          # across namespaces). One decision point: ScopeResolver.
          ScopeResolver.methods_for_receiver(meth, node.receiver, index, document) || []
        else
          ScopeResolver.bare_method(meth, nesting, index)
        end
      when Prism::DefNode
        # Hovering ON a definition: show that method's own signature/docs
        # (ruby-lsp does the same). The def's entry comes from the buffer
        # harvest (or VM for a compiled twin) under its qualified name.
        owner = nesting.empty? ? "Object" : nesting.join("::")
        sep = node.receiver ? "." : "#"
        index.definitions("#{owner}#{sep}#{node.name}")
      else
        # A literal value (string, number, array, hash, true/false/nil, range,
        # regexp, lambda, ...): hover shows its CLASS and where that class is
        # defined. A literal's class is always the core top-level class, so
        # resolve at top level (nesting []), never a lexically-nested shadow.
        # basic_type returns nil for non-literals -> no hover (unchanged).
        klass = Completion.basic_type(node)
        klass ? resolve_constant(klass, [], index) : []
      end
    end

    # Resolve a bare constant via the shared VM-anchored scope resolver.
    def resolve_constant(name, nesting, index)
      ScopeResolver.constant(name, nesting, index)
    end

    def render(entries, overrides = nil)
      return nil if entries.empty?
      title = signature_line(entries.first)

      # ruby-lsp shape (categorized_markdown_from_index_entries):
      #   ```ruby\n{title}\n```
      #
      #   **Definitions**: {link | link | ...}
      #
      #   {comments concatenated}
      links = entries.filter_map { |e| definition_link(e) }
      comments = entries.filter_map { |e| (e.doc unless e.doc.to_s.empty?) }

      # ruby-lsp's response builder appends each category with a trailing "\n"
      # then joins title/links/documentation with "\n", and the documentation
      # category itself leads with "\n\n". Net byte-exact layout:
      #   {title}\n\n**Definitions**: {links}\n\n\n\n{comments}
      out = +"```ruby\n#{title}\n```"
      out << "\n\n**Definitions**: #{links.join(' | ')}" unless links.empty?
      # What the displayed definition overrides/shadows, nearest -> oldest:
      # ancestor definers and a monkey-patched same-class VM twin. Absent when
      # nothing is overridden. Links open the shadowed definition.
      if overrides && !overrides.empty?
        rendered = overrides.map do |owner, entry|
          link = entry.uri.to_s.start_with?("file://") && definition_link(entry)
          link ? "#{owner} (#{link})" : owner
        end
        out << "\n\n**Overrides**: #{rendered.join(" → ")}"
      end
      out << "\n\n\n\n#{comments.join("\n\n")}" unless comments.empty?
      out
    end

    # ruby-lsp method title (handle_method_hover + decorated_parameters):
    #   "#{name}#{params}" where params is ALWAYS parenthesized, "()" if empty.
    # Class/module titles are the bare constant name (NO class/module keyword).
    def signature_line(entry)
      case entry.kind
      when :class, :module
        entry.name
      when :method
        name = method_name(entry.name)
        "#{name}#{decorated_parameters(entry)}"
      else
        entry.name
      end
    end

    # decorated_parameters: "(...)" always; "()" when the VM gave no params.
    def decorated_parameters(entry)
      p = entry.params.to_s
      return "()" if p.empty?
      p.start_with?("(") ? p : "(#{p})"
    end

    # ruby-lsp link (categorized_markdown_from_index_entries):
    #   uri = "#{entry.uri}#L#{start_line},#{start_col+1}-#{end_line},#{end_col+1}"
    #   "[#{file_name}](#{uri})"
    # Lines are zero-based; columns get +1. We have only a single line (the
    # VM's 1-based source_location) and no columns, so anchor start==end at the
    # zero-based line, columns 1 (== 0-based col 0, +1). Synthetic mruby-core://
    # entries have no file: link to the owning class with no fragment.
    def definition_link(entry)
      return nil unless entry.uri

      if entry.uri.start_with?("mruby-core://")
        "[#{entry.owner}](#{entry.uri})"
      else
        file = File.basename(entry.uri.sub(%r{\Afile://}, ""))
        if entry.range
          # Full def..end span with columns, matching ruby-lsp's link format:
          # #Lstart_line,start_col+1-end_line,end_col+1 (lines 1-based for the
          # markdown link; columns get +1).
          s = entry.range[:start]; e = entry.range[:end]
          frag = "#L#{s[:line] + 1},#{s[:character] + 1}-#{e[:line] + 1},#{e[:character] + 1}"
        else
          n = Integer(entry.line.to_s, exception: false)
          frag = n ? "#L#{n},1-#{n},1" : ""
        end
        "[#{file}](#{entry.uri}#{frag})"
      end
    end

    def method_name(qualified)
      sep = qualified.index("#") || qualified.index(".")
      sep ? qualified[(sep + 1)..] : qualified
    end
  end
end
