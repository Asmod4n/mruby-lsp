# frozen_string_literal: true

module MrubyLsp
  # Rendering of a method's parameter list into a Ruby signature string, plus the
  # parser that recovers the REAL parameter names from a C function's
  # `mrb_get_args` call. Both the VM reflection path (aspec kinds, unnamed) and
  # the C-source path (mrb_get_args, named) produce the same flat
  # [[kind, name], ...] shape and render through ParamFormat.render, so a
  # signature looks identical no matter where its facts came from.
  module ParamFormat
    module_function

    # pairs: flat [[kind, name], ...]; name may be nil (unnamed C spec). Renders
    # "(a, b = ..., *rest, key:, **opts, &blk)". Unnamed positionals get numbered
    # argN placeholders; nil/empty -> "()".
    def render(pairs)
      return "()" if pairs.nil? || pairs.empty?
      n = 0
      parts = pairs.filter_map do |pair|
        kind, name = Array(pair)
        nm = clean_name(name)
        case kind
        when :req     then n += 1; nm || "arg#{n}"
        when :opt     then n += 1; "#{nm || "arg#{n}"} = ..."
        when :rest    then "*#{nm || "args"}"
        when :keyrest then "**#{nm || "opts"}"
        when :key     then "#{nm || "key"}:"
        when :block   then "&#{nm || "block"}"
        else nm
        end
      end
      "(#{parts.join(", ")})"
    end

    # mruby's C-method param reflection sometimes reports the SIGIL itself as the
    # name (rest -> "*", keyrest -> "**", block -> "&"). Treat sigil-only or empty
    # names as unnamed so we don't double the sigil ("**", "****", "&&").
    def clean_name(name)
      return nil if name.nil?
      n = name.to_s
      return nil if n.empty?
      return nil if n.chars.all? { |c| c == "*" || c == "&" }
      n
    end
  end

  # Parse a C `mrb_get_args(mrb, "fmt", &a, &b, ...)` call into [[kind, name], ...]
  # using the documented format spec (see mruby.h). The format string is the
  # ground truth for a C method's real signature -- it carries the names the
  # author chose AND the req/opt/rest/block structure (which mruby's own
  # Method#parameters mangles for C methods). Returns nil when no parseable call
  # is present (no literal format, an unknown directive, etc.) -> caller falls
  # back to the aspec-derived (unnamed) signature.
  module GetArgs
    module_function

    # specifier -> [C-arg slots consumed, kind]. kind: :pos (req unless after
    # '|'), :rest, :block, :kw (keyword args -> **opts; names live in a separate
    # array we don't read), :skip (consumes a slot but is not a Ruby parameter).
    # The principal NAME is always the FIRST slot; extra slots (lengths, the data
    # type for 'd') are auxiliary and unnamed.
    SPEC = {
      "o" => [1, :pos], "C" => [1, :pos], "S" => [1, :pos], "A" => [1, :pos],
      "H" => [1, :pos], "z" => [1, :pos], "c" => [1, :pos], "f" => [1, :pos],
      "i" => [1, :pos], "b" => [1, :pos], "n" => [1, :pos], "I" => [1, :pos],
      "s" => [2, :pos], "a" => [2, :pos], "d" => [2, :pos],
      "*" => [2, :rest], "&" => [1, :block], "?" => [1, :skip], ":" => [1, :kw],
    }.freeze

    # text: a C function body (bounded to one function). Returns [[kind, name], ...]
    # or nil.
    def specs(text)
      fmt, vars = extract(text)
      return nil unless fmt
      parse(fmt, vars)
    end

    # Walk the format, consuming var slots; build the param pairs.
    def parse(fmt, vars)
      pairs = []
      vi = 0
      optional = false
      i = 0
      while i < fmt.length
        ch = fmt[i]
        if ch == "|"
          optional = true
          i += 1
          next
        end
        if ch == "!" || ch == "+"   # modifiers on the previous spec: no slot
          i += 1
          next
        end
        spec = SPEC[ch] or return nil   # unknown directive: don't guess
        slots, kind = spec
        name = vars[vi]                 # principal name = first slot
        vi += slots
        case kind
        when :pos   then pairs << [optional ? :opt : :req, name]
        when :rest  then pairs << [:rest, name]
        when :block then pairs << [:block, name]
        when :kw    then pairs << [:keyrest, nil]
        when :skip  then nil            # e.g. '?': a "given" bool, not a param
        end
        i += 1
      end
      pairs
    end

    # Find the FIRST mrb_get_args(...) call in `text` and return [format, vars]
    # ([String, Array<String|nil>]) or nil. The format must be a string literal;
    # each var is reduced to a plain C identifier (a complex expression -> nil,
    # which renders as a numbered placeholder).
    def extract(text)
      m = text.match(/\bmrb_get_args\s*\(/) or return nil
      args = split_top(balanced(text[m.end(0)..]))
      return nil if args.nil? || args.length < 2
      fmt = string_literal(args[1]) or return nil
      [fmt, args[2..].map { |a| varname(a) }]
    end

    # Capture chars up to the paren that closes the already-open '(' (depth 1).
    def balanced(s)
      return nil unless s
      depth = 1
      buf = +""
      s.each_char do |c|
        depth += 1 if c == "("
        depth -= 1 if c == ")"
        break if depth.zero?
        buf << c
      end
      depth.zero? ? buf : nil   # unbalanced (call spilled past our window) -> nil
    end

    # Split on top-level commas (ignoring those nested in ()/[]/{}).
    def split_top(s)
      return nil unless s
      out = []
      depth = 0
      cur = +""
      s.each_char do |c|
        depth += 1 if "([{".include?(c)
        depth -= 1 if ")]}".include?(c)
        if c == "," && depth.zero?
          out << cur
          cur = +""
        else
          cur << c
        end
      end
      out << cur
      out.map(&:strip)
    end

    # Concatenate adjacent string literals ("ab" "cd" -> "abcd"); unescape simple
    # backslash escapes. nil if the expression isn't a string literal (a macro /
    # variable format -> we can't parse it).
    def string_literal(s)
      parts = s.scan(/"((?:\\.|[^"\\])*)"/).map(&:first)
      return nil if parts.empty?
      # the whole expression must be just string literals (+ whitespace), else
      # it's something like `fmt_for(x)` we shouldn't treat as a literal.
      return nil unless s.strip.gsub(/"(?:\\.|[^"\\])*"/, "").strip.empty?
      parts.join.gsub(/\\(.)/, '\1')
    end

    def varname(arg)
      a = arg.to_s.strip.sub(/\A&/, "")
      a.match?(/\A[A-Za-z_]\w*\z/) ? a : nil
    end
  end
end
