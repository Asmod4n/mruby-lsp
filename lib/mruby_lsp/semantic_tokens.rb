# frozen_string_literal: true

require "set"
require "prism"
require_relative "locator"

module MrubyLsp
  # textDocument/semanticTokens/full — semantic highlighting.
  #
  # Mirrors ruby-lsp's SemanticHighlighting listener rule-for-rule (legend, delta
  # encoding, and which nodes become which token), with ONE principled
  # difference: the "special methods" set (built-ins TextMate already colors, so
  # we don't emit a token) is sourced from the LIVE mruby VM (Kernel/Module own
  # methods), NOT host CRuby. ruby-lsp derives it from CRuby because its runtime
  # IS CRuby; ours is mruby, so where mruby's Kernel/Module differ (e.g. no
  # `require`) we correctly differ.
  module SemanticTokens
    module_function

    TOKEN_TYPES = %w[
      namespace type class enum interface struct typeParameter parameter
      variable property enumMember event function method macro keyword modifier
      comment string number regexp operator decorator
    ].freeze

    TOKEN_MODIFIERS = %w[
      declaration definition readonly static deprecated abstract async
      modification documentation defaultLibrary
    ].freeze

    TYPE_INDEX = TOKEN_TYPES.each_with_index.to_h.freeze
    MOD_INDEX = TOKEN_MODIFIERS.each_with_index.to_h.freeze

    def legend
      { tokenTypes: TOKEN_TYPES, tokenModifiers: TOKEN_MODIFIERS }
    end

    ENCODINGS = {
      "utf-8" => Encoding::UTF_8,
      "utf-16" => Encoding::UTF_16LE,
      "utf-32" => Encoding::UTF_32LE,
    }.freeze

    # special_methods: Set<String> of mruby built-in method names (from the VM).
    # nil/empty -> no suppression (degraded, no VM).
    def response(document, special_methods = nil)
      { data: encode(collect_tokens(document, special_methods)) }
    end

    # textDocument/semanticTokens/range — same tokens, restricted to those on a
    # line the range covers. ruby-lsp filters purely by line (inclusive of both
    # the start and end line), ignoring the range's character coordinates:
    # `(start.line..end.line).cover?(token.line)`.
    def response_range(document, special_methods, range)
      toks = collect_tokens(document, special_methods)
      lines = (range[:start][:line]..range[:end][:line])
      { data: encode(toks.select { |t| lines.cover?(t[:line]) }) }
    end

    def collect_tokens(document, special_methods)
      enc = ENCODINGS[(defined?(Locator) ? Locator.encoding : nil)] || Encoding::UTF_16LE
      cache = document.ast.code_units_cache(enc)
      c = Collector.new(special_methods || Set.new, cache)
      c.visit(document.ast.value)
      c.tokens.sort_by { |t| [t[:line], t[:char]] }
    end

    # LSP delta encoding: 5 ints per token
    # [deltaLine, deltaStartChar, length, tokenType, tokenModifiers].
    def encode(tokens)
      data = []
      prev_line = 0
      prev_char = 0
      tokens.each do |t|
        d_line = t[:line] - prev_line
        d_char = d_line.zero? ? t[:char] - prev_char : t[:char]
        data.push(d_line, d_char, t[:length], t[:type], t[:mods])
        prev_line = t[:line]
        prev_char = t[:char]
      end
      data
    end

    # Per-def/block lexical scope. Tracks ONLY parameters (ruby-lsp does the
    # same): a name present here is a :parameter, absent -> :variable.
    class Scope
      attr_reader :parent

      def initialize(parent = nil)
        @parent = parent
        @locals = {}
      end

      def add(name, type)
        @locals[name.to_sym] = type
      end

      def lookup(name)
        sym = name.to_sym
        @locals[sym] || @parent&.lookup(sym)
      end
    end

    # Stateful visitor mirroring ruby-lsp's listener. enter() before children,
    # leave() after, so scope push/pop and the implicit/regex guards nest right.
    class Collector
      attr_reader :tokens

      def initialize(special_methods, cache)
        @tokens = []
        @scope = Scope.new
        @special = special_methods
        @cache = cache
        @inside_implicit = false
        @inside_regex = false
      end

      def visit(node)
        return unless node.is_a?(Prism::Node)
        enter(node)
        node.compact_child_nodes.each { |c| visit(c) }
        leave(node)
      end

      def enter(node)
        case node
        when Prism::ClassNode    then on_class(node)
        when Prism::ModuleNode   then on_module(node)
        when Prism::DefNode, Prism::BlockNode
          @scope = Scope.new(@scope)
        when Prism::RequiredParameterNode, Prism::OptionalParameterNode,
             Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode
          @scope.add(node.name, :parameter)
        when Prism::RestParameterNode, Prism::KeywordRestParameterNode,
             Prism::BlockParameterNode
          n = node.name
          @scope.add(n, :parameter) if n
        when Prism::BlockLocalVariableNode
          add(node.location, :variable, [])
        when Prism::SelfNode
          add(node.location, :variable, [:defaultLibrary])
        when Prism::LocalVariableWriteNode, Prism::LocalVariableAndWriteNode,
             Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode
          add(node.name_loc, :parameter, []) if @scope.lookup(node.name) == :parameter
        when Prism::LocalVariableReadNode
          on_lvar_read(node)
        when Prism::LocalVariableTargetNode
          unless @inside_regex
            t = @scope.lookup(node.name) || :variable
            add(node.location, t, [])
          end
        when Prism::CallNode
          on_call(node)
        when Prism::MatchWriteNode
          on_match_write_enter(node)
        when Prism::ImplicitNode
          @inside_implicit = true
        end
      end

      def leave(node)
        case node
        when Prism::DefNode, Prism::BlockNode
          @scope = @scope.parent
        when Prism::ImplicitNode
          @inside_implicit = false
        when Prism::MatchWriteNode
          @inside_regex = false if node.call.message == "=~"
        end
      end

      def on_lvar_read(node)
        return if @inside_implicit
        # Numbered parameters (_1, _2, ...). Same loose check ruby-lsp uses.
        if /_\d+/.match?(node.name.to_s)
          add(node.location, :parameter, [])
          return
        end
        t = @scope.lookup(node.name) || :variable
        add(node.location, t, [])
      end

      def on_call(node)
        return if @inside_implicit
        msg = node.message
        return unless msg
        # [] / []= and =~ carry their args inside message_loc -> no token.
        return if msg.start_with?("[") && (msg.end_with?("]") || msg.end_with?("]="))
        return if msg == "=~"
        return if @special.include?(msg)
        # Only the ambiguous case (implicit self, no parens) needs a :method
        # token to distinguish it from a local variable.
        if node.receiver.nil? && node.opening_loc.nil? && node.message_loc
          add(node.message_loc, :method, [])
        end
      end

      def on_class(node)
        cp = node.constant_path
        if cp.is_a?(Prism::ConstantReadNode)
          add(cp.location, :class, [:declaration])
        else
          each_constant_part(cp) { |loc| add(loc, :class, [:declaration]) }
        end
        sc = node.superclass
        if sc.is_a?(Prism::ConstantReadNode)
          add(sc.location, :class, [])
        elsif sc
          each_constant_part(sc) { |loc| add(loc, :class, []) }
        end
      end

      def on_module(node)
        cp = node.constant_path
        if cp.is_a?(Prism::ConstantReadNode)
          add(cp.location, :namespace, [:declaration])
        else
          each_constant_part(cp) { |loc| add(loc, :namespace, [:declaration]) }
        end
      end

      # Yield each constant-path part's name location, outermost handled by the
      # recursion (matches ruby-lsp's each_constant_path_part shape).
      def each_constant_part(node)
        parts = []
        cur = node
        while cur.is_a?(Prism::ConstantPathNode)
          parts << cur.name_loc
          cur = cur.parent
        end
        parts << cur.location if cur.is_a?(Prism::ConstantReadNode)
        parts.each { |loc| yield loc if loc }
      end

      def on_match_write_enter(node)
        call = node.call
        return unless call.message == "=~"
        @inside_regex = true
        process_regexp_locals(call)
      end

      # Named regex captures (`/(?<x>..)/ =~ s`) bind locals -> tokenize each.
      def process_regexp_locals(node)
        receiver = node.receiver
        return unless receiver.is_a?(Prism::RegularExpressionNode)
        content = receiver.content
        loc = receiver.content_loc
        Regexp.new(content, Regexp::FIXEDENCODING).names.each do |name|
          idx = content.index("(?<#{name}>")
          next unless idx
          off = idx + 3 # skip "(?<"
          lv = loc.copy(start_offset: loc.start_offset + off, length: name.length)
          t = @scope.lookup(name) || :variable
          add(lv, t, [])
        end
      end

      def add(loc, type, mods)
        # Columns/lengths in the negotiated position encoding's code units, via
        # Prism's code-unit cache — the exact mechanism ruby-lsp uses, so the
        # numbers match for any client encoding (utf-8/utf-16/utf-32).
        char = loc.cached_start_code_units_column(@cache)
        length = loc.cached_end_code_units_offset(@cache) -
                 loc.cached_start_code_units_offset(@cache)
        @tokens << {
          line: loc.start_line - 1,
          char: char,
          length: length,
          type: TYPE_INDEX.fetch(type.to_s, 0),
          mods: mods.sum { |m| 1 << MOD_INDEX.fetch(m.to_s, 0) },
        }
      end
    end
  end
end
