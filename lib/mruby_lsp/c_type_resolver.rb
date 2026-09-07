# frozen_string_literal: true

require_relative "c_return_type"
require_relative "inline_type"
require_relative "param_format"
require_relative "block_params"

module MrubyLsp
  # C-symbol gateway to our managed clangd, keyed by (source file + function
  # name, from CLocator's addr2line). Two services, both lazy and memoized:
  #   - return type (Stage 3): the function's AST -> CReturnType.
  #   - doc: the leading comment, VERBATIM (clangd is a real C/C++ frontend, so
  #     it lexes string/char literals, // vs /* */, and line-continuation right;
  #     a line scanner cannot). Returned unmodified (only stripped) so a later
  #     rbs pass can read inline-RBS annotations out of the raw comment text.
  #
  # Lazy and memoized: a file is didOpen'd + documentSymbol'd at most once (to
  # find each function's range); each function is typed at most once. Nothing
  # happens until a C method is actually used as a typed receiver, so startup
  # pays nothing (the 1990-entries-at-populate stall stays avoided).
  #
  # Degrade: if the clangd client is nil/dead (clangd not on PATH, no
  # compile_commands.json, parse failure), every lookup returns nil -> Stage 3 is
  # simply off, exactly like the irep gem being absent for Stage 2.
  class CTypeResolver
    # Max nested helper hops the interprocedural return-type step follows
    # (`return io_init(mrb, obj)` is one hop). Bounded so a pathological chain can
    # never stall an editor request; real init-helpers are one or two deep.
    HOP_LIMIT = 3

    def initialize(client)
      @client  = client
      @ranges  = {} # file => { func => { range:, pos: } } | nil  (per-file, once)
      @types   = {} # [file, func] => class | RECEIVER | nil       (per-function memo)
      @docs    = {} # [file, func] => String | nil                (per-function memo)
      @params  = {} # [file, func] => [[kind,name],...] | nil      (per-function memo)
      @yields  = {} # [file, func] => [name,...] | nil            (per-function memo)
      @helpers = {} # [file, func] => classify result             (interproc. memo + cycle guard)
    end

    def alive? = @client && @client.alive?

    # The function's leading doc comment, VERBATIM (clangd's documentation for
    # the symbol). nil if clangd is dead, the function isn't found, or there is
    # no comment. Not reformatted -- a future rbs pass parses the raw text.
    # `line` is the definition line addr2line reported with the name; it places
    # a C++ function whose name clangd spells differently (see #symbol_for).
    def doc(file, func, line = nil)
      return nil unless alive? && file && func
      key = [file, func]
      return @docs[key] if @docs.key?(key)
      @docs[key] = compute_doc(file, func, line)
    end

    # The REAL parameter names of a C method, parsed from its `mrb_get_args`
    # call. -> flat [[kind, name], ...] or nil (no clangd, function not found, or
    # no parseable mrb_get_args). The format string is more faithful than mruby's
    # own Method#parameters: it carries the author's names AND the true
    # req/opt/rest/block split. Bounded to the one function via clangd's symbol
    # range so we never read a neighbour's call. Lazy + memoized per function.
    def arg_specs(file, func, line = nil)
      return nil unless alive? && file && func
      key = [file, func]
      return @params[key] if @params.key?(key)
      @params[key] = compute_arg_specs(file, func, line)
    end

    # The block parameter NAMES of a C method, read from what it hands its block
    # (mrb_yield / mrb_funcall on the captured block var -- see BlockParams). ->
    # [name, ...] or nil. Lazy + memoized per function, like arg_specs.
    def yield_args(file, func, line = nil)
      return nil unless alive? && file && func
      key = [file, func]
      return @yields[key] if @yields.key?(key)
      @yields[key] = BlockParams.from_c(function_body(file, func, line))
    end

    # file: absolute C source path; func: the C function name. -> class | nil.
    def resolve(file, func, line = nil)
      return nil unless alive? && file && func
      key = [file, func]
      return @types[key] if @types.key?(key)
      @types[key] = compute(file, func, line)
    end

    private

    # THIS function's body text, bounded to clangd's symbol range so a scan never
    # picks up a neighbour's call. nil when clangd can't place the function.
    def function_body(file, func, line = nil)
      rng = symbol_for(file, func, line)&.dig(:range)
      return nil unless rng
      lines = source_lines(file)
      return nil unless lines
      a = rng.dig(:start, :line)
      b = rng.dig(:end, :line) || a
      return nil unless a
      lines[a..b]&.join("\n")
    end

    def compute_arg_specs(file, func, line = nil)
      body = function_body(file, func, line) or return nil
      GetArgs.specs(body)
    end

    def compute(file, func, line = nil)
      rng = symbol_for(file, func, line)&.dig(:range)
      return nil unless rng
      # A hand-written `//:` annotation above the function is the contract and
      # wins over the clangd-AST inference (symmetric with the Ruby `#:` path).
      ann = annotation_return(file, rng)
      return ann if ann
      CReturnType.of(function_ast(file, rng), resolve_callee: callee_resolver(file, 1))
    end

    # The clangd AST subtree for one function (its documentSymbol range).
    def function_ast(file, rng)
      @client.request("textDocument/ast", textDocument: { uri: "file://#{file}" }, range: rng)
    end

    # A callable `name -> CReturnType.classify(<helper>)` for SAME-FILE helpers,
    # so the return-type analysis can follow `return io_init(mrb, obj)`. Bounded
    # to HOP_LIMIT nested hops (nil past it -> stop following, never loop). The
    # memo doubles as a cycle guard: a helper is seeded nil before it is analysed,
    # so a self/mutually-recursive call sees nil and the chain terminates.
    def callee_resolver(file, depth)
      return nil if depth > HOP_LIMIT
      lambda do |name|
        key = [file, name]
        return @helpers[key] if @helpers.key?(key)
        @helpers[key] = nil
        rng = ranges_for(file)&.dig(name, :range)
        @helpers[key] =
          rng && CReturnType.classify(function_ast(file, rng),
                                      resolve_callee: callee_resolver(file, depth + 1))
      end
    end

    # The return class named by a `//:` annotation just above the C function, or
    # nil. clangd's symbol range starts at the definition; the annotation sits
    # above it, typically separated by the return-type/storage line
    # (`static mrb_value`). Scan a few physical lines up: skip blanks for free,
    # spend a small budget on storage/return-type lines, take the first `//:`,
    # and stop at the end of the previous decl/statement so we never read a
    # neighbouring function's annotation.
    def annotation_return(file, rng)
      start = rng.dig(:start, :line)        # LSP range lines are 0-based
      return nil unless start && start > 0
      lines = source_lines(file)
      return nil unless lines
      i = start - 1
      budget = 3
      while i >= 0 && budget > 0
        raw = lines[i].to_s
        s = raw.strip
        if s.empty?
          i -= 1
          next                              # blank line: free to skip
        end
        mt = InlineType.extract(raw)
        return InlineType.return_class_name(mt) if mt
        break if s.end_with?("}", ";")      # previous decl/stmt ended -> no annotation
        i -= 1
        budget -= 1                         # a storage/return-type line: bounded skip
      end
      nil
    end

    # The clangd symbol a name from addr2line stands for. In C the two spell a
    # function the same. In C++ they do not: addr2line reports the demangled,
    # QUALIFIED definition -- "webmachine::(anonymous namespace)::watcher_events
    # (mrb_state*, mrb_value)" -- while clangd's documentSymbol carries the bare
    # "watcher_events". So a name lookup misses every function of the gem, and
    # Stage 3, the C doc comments and the real parameter names all go dark for
    # it. One .cpp anywhere makes mruby build the whole gem with the C++
    # compiler, so this is an ordinary mruby gem, not a corner case.
    #
    # Do not take the name apart -- a demangled name is structured text (the
    # first "(" here opens "(anonymous namespace)", not the parameter list).
    # addr2line reports the definition's own LINE beside the name, so the
    # fallback is structural: the function whose clangd range holds that line.
    # Only an unambiguous hit counts, so a line that lands between functions
    # resolves to nothing rather than to a neighbour.
    def symbol_for(file, func, line = nil)
      map = ranges_for(file) or return nil
      named = map[func]
      return named if named
      return nil unless line

      ln = line.to_i - 1 # addr2line counts lines from 1, LSP ranges from 0
      return nil if ln.negative?
      hits = map.each_value.select { |s| covers?(s[:range], ln) }
      hits.size == 1 ? hits.first : nil
    end

    def covers?(range, ln)
      a = range.dig(:start, :line)
      b = range.dig(:end, :line) || a
      !a.nil? && ln >= a && ln <= b
    end

    # A C source as text. Read as UTF-8 and scrubbed, NEVER through the process
    # default encoding: with LANG unset that default is US-ASCII, every source
    # byte over 127 makes the string invalid, and the first scan of it
    # (GetArgs' mrb_get_args match) raises ArgumentError -- inside the request
    # thread, which dies and takes every C answer of the session with it. One
    # comment character in one core file was enough. Degrade, don't crash.
    def source_text(file)
      File.read(file, encoding: "BINARY").force_encoding("UTF-8").scrub
    end

    def source_lines(file)
      @src_lines ||= {}
      return @src_lines[file] if @src_lines.key?(file)
      @src_lines[file] = begin
        source_text(file).lines(chomp: true)
      rescue StandardError
        nil
      end
    end

    def compute_doc(file, func, line = nil)
      sym = symbol_for(file, func, line) # ensures the TU is open + parsed
      return nil unless sym
      name = sym[:name]
      uri = "file://#{file}"
      src = source_text(file)
      # clangd fills a completion item\'s documentation with the comment ALONE
      # (no signature/params/decl blob, unlike hover) -- but only at a USE site,
      # which a definition has none of. So feed clangd one: a throwaway function
      # naming this symbol, complete there, read its documentation, then restore
      # the buffer. The REAL uri keeps the real compile flags so the TU parses.
      #
      # The stub goes on the line right AFTER the definition, not at the end of
      # the file. A C++ gem defines its methods in a namespace -- usually an
      # anonymous one -- and at file scope the name is not visible, so an
      # appended stub completes to nothing and every C++ method loses its doc
      # comment. Directly after the definition the stub sits in the function's
      # own scope, whatever that is, and the same line serves C. It is the
      # structural answer: the range is the one clangd itself reported.
      lines = src.lines
      last = sym.dig(:range, :end, :line)
      at = last ? last + 1 : lines.size
      at = lines.size if at > lines.size
      # A file whose last line has no newline would glue the stub onto it.
      lines[at - 1] = "#{lines[at - 1]}\n" if at.positive? && !lines[at - 1].to_s.end_with?("\n")
      head = "void __mruby_lsp_doc_probe__(void){(void)#{name[0, name.length - 1]}"
      lines.insert(at, "#{head}\n;}\n")
      @client.did_change(uri, lines.join)
      pos = { line: at, character: head.length }
      res = @client.request("textDocument/completion", textDocument: { uri: uri }, position: pos)
      items = res.is_a?(Hash) ? res[:items] : res
      item = Array(items).find do |i|
        [i[:label], i[:filterText], i[:insertText]].compact.any? { |x| x.to_s.strip == name }
      end
      return nil unless item
      doc = item[:documentation]
      doc = (@client.request("completionItem/resolve", item) || {})[:documentation] if doc.nil?
      val = strip_annotations(doc.is_a?(Hash) ? doc[:value] : doc)
      (val && !val.to_s.strip.empty?) ? val.strip : nil
    ensure
      @client.did_change(uri, src) if defined?(src) && src
    end

    # A `//:` annotation is a contract, not documentation, and the type it
    # names is already surfaced as the return type. clangd counts the line as
    # part of the leading comment though (with the `//` gone), so without this
    # the reader is shown a stray ": () -> Hash" at the end of the doc.
    def strip_annotations(text)
      return nil if text.nil?

      text.to_s.lines.reject { |l| InlineType.annotation_line?(l) }.join
    end

    # didOpen the file once, documentSymbol once -> name => range. clangd returns
    # SymbolInformation[] (flat, location.range); functions are SymbolKind 12.
    def ranges_for(file)
      return @ranges[file] if @ranges.key?(file)
      @ranges[file] =
        begin
          uri = "file://#{file}"
          @client.did_open(uri, source_text(file))
          syms = @client.request("textDocument/documentSymbol", textDocument: { uri: uri }) || []
          map = {}
          syms.each do |s|
            next unless s[:kind] == 12 # Function
            r = s.dig(:location, :range) || s[:range]
            next unless r && s[:name]
            # selectionRange (hierarchical DocumentSymbol) points at the name;
            # for flat SymbolInformation, location.range is the symbol itself.
            # pos drives hover (must sit ON the symbol); range drives the AST.
            pos = (s[:selectionRange] || r)[:start]
            map[s[:name]] = { name: s[:name], range: r, pos: pos }
          end
          map
        end
    end
  end
end
