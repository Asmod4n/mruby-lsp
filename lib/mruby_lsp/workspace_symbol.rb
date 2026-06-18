# frozen_string_literal: true

module MrubyLsp
  # workspace/symbol — query the index for symbols whose name matches the query,
  # returning SymbolInformation[] in ruby-lsp's shape (verified against the
  # running server):
  #   { name, kind, containerName, location:{ uri, range } }
  # Content is VM/buffer-backed (our index), not workspace .rb files, but the
  # SHAPE matches. Only entries with a real file:// location are returned (a
  # SymbolInformation needs a navigable location, like ruby-lsp).
  module WorkspaceSymbol
    module_function

    # LSP SymbolKind ints (same mapping ruby-lsp uses).
    KIND = { class: 5, module: 2, method: 6, constant: 14 }.freeze

    def response(index, query)
      q = query.to_s
      seen = {}
      ranked = index.prefix("").each_with_object([]) do |entry, out|
        short = short_name(entry.name)
        tier = match_tier(short, q)
        next unless tier
        next unless entry.uri && entry.uri.start_with?("file://")
        key = [entry.name, entry.uri, entry.line]
        next if seen[key]
        seen[key] = true
        out << [tier, short.length, short, symbol_information(entry, short)]
      end
      # Rank: exact, then prefix, then subsequence; within a tier shorter names
      # first, then alphabetical. (The client re-ranks too, but a sensible server
      # order keeps the best matches near the top.)
      ranked.sort_by { |tier, len, name, _| [tier, len, name] }.map(&:last)
    end

    # nil = no match; 0 = exact, 1 = prefix, 2 = subsequence (case-insensitive).
    # ruby-lsp uses a scored fuzzy_search; we approximate with tiers, which is
    # enough for a useful order on top of the client's own filtering.
    def match_tier(name, query)
      return 0 if query.empty?
      n = name.downcase
      q = query.downcase
      return 0 if n == q
      return 1 if n.start_with?(q)
      i = 0
      q.each_char do |c|
        i = n.index(c, i)
        return nil unless i
        i += 1
      end
      2
    end

    def symbol_information(entry, short)
      line = line_of(entry)
      {
        name: short,
        kind: KIND.fetch(entry.kind, 14),
        containerName: container_of(entry),
        location: {
          uri: entry.uri,
          range: {
            start: { line: line, character: 0 },
            end:   { line: line, character: 0 }
          }
        }
      }
    end

    def short_name(qualified)
      sep = qualified.rindex("#") || qualified.rindex(".")
      sep ? qualified[(sep + 1)..] : qualified
    end

    def container_of(entry)
      entry.owner.to_s == short_name(entry.name) ? "" : entry.owner.to_s
    end

    def line_of(entry)
      raw = entry.line.to_s
      raw.match?(/\A\d+\z/) ? [raw.to_i - 1, 0].max : 0
    end
  end
end
