# frozen_string_literal: true

require_relative "c_return_type"
require_relative "inline_type"
require_relative "param_format"

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
    def initialize(client)
      @client = client
      @ranges = {} # file => { func => { range:, pos: } } | nil  (per-file, once)
      @types  = {} # [file, func] => class | nil                 (per-function memo)
      @docs   = {} # [file, func] => String | nil                (per-function memo)
      @params = {} # [file, func] => [[kind,name],...] | nil      (per-function memo)
    end

    def alive? = @client && @client.alive?

    # The function's leading doc comment, VERBATIM (clangd's documentation for
    # the symbol). nil if clangd is dead, the function isn't found, or there is
    # no comment. Not reformatted -- a future rbs pass parses the raw text.
    def doc(file, func)
      return nil unless alive? && file && func
      key = [file, func]
      return @docs[key] if @docs.key?(key)
      @docs[key] = compute_doc(file, func)
    end

    # The REAL parameter names of a C method, parsed from its `mrb_get_args`
    # call. -> flat [[kind, name], ...] or nil (no clangd, function not found, or
    # no parseable mrb_get_args). The format string is more faithful than mruby's
    # own Method#parameters: it carries the author's names AND the true
    # req/opt/rest/block split. Bounded to the one function via clangd's symbol
    # range so we never read a neighbour's call. Lazy + memoized per function.
    def arg_specs(file, func)
      return nil unless alive? && file && func
      key = [file, func]
      return @params[key] if @params.key?(key)
      @params[key] = compute_arg_specs(file, func)
    end

    # file: absolute C source path; func: the C function name. -> class | nil.
    def resolve(file, func)
      return nil unless alive? && file && func
      key = [file, func]
      return @types[key] if @types.key?(key)
      @types[key] = compute(file, func)
    end

    private

    def compute_arg_specs(file, func)
      rng = ranges_for(file)&.dig(func, :range)
      return nil unless rng
      lines = source_lines(file)
      return nil unless lines
      # Bound the scan to THIS function's body (clangd's symbol range), so a
      # function with no mrb_get_args doesn't pick up the next function's call.
      a = rng.dig(:start, :line)
      b = rng.dig(:end, :line) || a
      return nil unless a
      body = lines[a..b]&.join("\n") or return nil
      GetArgs.specs(body)
    end

    def compute(file, func)
      rng = ranges_for(file)&.dig(func, :range)
      return nil unless rng
      # A hand-written `//:` annotation above the function is the contract and
      # wins over the clangd-AST inference (symmetric with the Ruby `#:` path).
      ann = annotation_return(file, rng)
      return ann if ann
      uri = "file://#{file}"
      ast = @client.request("textDocument/ast", textDocument: { uri: uri }, range: rng)
      CReturnType.of(ast)
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

    def source_lines(file)
      @src_lines ||= {}
      return @src_lines[file] if @src_lines.key?(file)
      @src_lines[file] = begin
        File.readlines(file, chomp: true)
      rescue StandardError
        nil
      end
    end

    def compute_doc(file, func)
      return nil unless ranges_for(file) # ensures the TU is open + parsed
      uri = "file://#{file}"
      src = File.read(file)
      # clangd fills a completion item\'s documentation with the comment ALONE
      # (no signature/params/decl blob, unlike hover) -- but only at a USE site,
      # which a definition has none of. So feed clangd one: append a throwaway
      # function naming this symbol, complete there, read its documentation, then
      # restore the buffer. The REAL uri keeps the real compile flags so the TU
      # parses; the stub is appended, so cached ranges stay valid.
      head = "void __mruby_lsp_doc_probe__(void){(void)#{func[0, func.length - 1]}"
      @client.did_change(uri, "#{src}\n#{head}\n;}\n")
      pos = { line: src.lines.size + 1, character: head.length }
      res = @client.request("textDocument/completion", textDocument: { uri: uri }, position: pos)
      items = res.is_a?(Hash) ? res[:items] : res
      item = Array(items).find do |i|
        [i[:label], i[:filterText], i[:insertText]].compact.any? { |x| x.to_s.strip == func }
      end
      return nil unless item
      doc = item[:documentation]
      doc = (@client.request("completionItem/resolve", item) || {})[:documentation] if doc.nil?
      val = doc.is_a?(Hash) ? doc[:value] : doc
      (val && !val.to_s.strip.empty?) ? val.strip : nil
    ensure
      @client.did_change(uri, src) if defined?(src) && src
    end

    # didOpen the file once, documentSymbol once -> name => range. clangd returns
    # SymbolInformation[] (flat, location.range); functions are SymbolKind 12.
    def ranges_for(file)
      return @ranges[file] if @ranges.key?(file)
      @ranges[file] =
        begin
          uri = "file://#{file}"
          @client.did_open(uri, File.read(file))
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
            map[s[:name]] = { range: r, pos: pos }
          end
          map
        end
    end
  end
end
