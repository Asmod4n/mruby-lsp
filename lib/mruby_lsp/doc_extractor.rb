# frozen_string_literal: true

require "prism"

module MrubyLsp
  # Leading doc comment for a method, from its real source.
  #
  # Ruby only: the contiguous '#' comment block immediately above the def, via
  # Prism (result.comments + DefNode). No regex, no parser-internals coupling.
  #
  # C methods are NOT handled here. A C comment's extent is not a line property
  # ("does this line end in */") -- whether a /*, */ or // even starts a comment
  # depends on lexer state (inside a string/char literal? a line continuation?),
  # and a single line can hold many comments and code between them. That is not a
  # regular language, so a line scanner is simply wrong. We ask clangd instead (a
  # real C/C++ frontend); see CTypeResolver#doc. No clangd -> no C comments.
  #
  # Files are parsed once and cached. Returns a normalized doc string or nil.
  class DocExtractor
    MAX_CACHED_FILES = 16

    def initialize
      @ruby_cache = {} # path -> { def_line => doc }
    end

    # Ruby method doc: the '#' comment block ending just above the def line.
    # path: filesystem path; def_line: 1-based line of the `def`.
    def ruby_doc(path, def_line)
      return nil unless path && def_line && File.file?(path)

      @ruby_cache.shift while @ruby_cache.size >= MAX_CACHED_FILES
      table = (@ruby_cache[path] ||= build_ruby_table(path))
      (t = table[def_line]) && tidy(t)
    end

    private

    def build_ruby_table(path)
      source = File.read(path)
      result = Prism.parse(source)

      # Map comment line -> text, for contiguous-block lookup.
      comment_by_line = {}
      result.comments.each do |c|
        line = c.location.start_line
        comment_by_line[line] = strip_hash(c.slice)
      end

      table = {}
      each_def_node(result.value) do |def_node|
        def_line = def_node.location.start_line
        doc = collect_block_above(comment_by_line, def_line)
        table[def_line] = doc if doc
      end
      table
    end

    def each_def_node(node, &block)
      return unless node.is_a?(Prism::Node)

      block.call(node) if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each { |child| each_def_node(child, &block) }
    end

    # Walk upward from def_line-1 while consecutive comment lines exist.
    def collect_block_above(comment_by_line, def_line)
      lines = []
      line = def_line - 1
      while comment_by_line.key?(line)
        lines.unshift(comment_by_line[line])
        line -= 1
      end
      return nil if lines.empty?

      lines.join("\n").strip.then { |s| s.empty? ? nil : s }
    end

    # Drop leading blank / bare-"#" separator lines so docs don't start with
    # stray markers, and fence a leading call-seq: block as code so markdown
    # hover doesn't run the signatures together.
    def tidy(text)
      lines = text.lines.drop_while { |l| l.strip.empty? || l.strip == "#" }
      if lines.first&.strip == "call-seq:"
        seq = lines.drop(1).take_while { |l| !l.strip.empty? }
        rest = lines.drop(1 + seq.size)
        lines = ["```\n", *seq.map { |l| l.sub(/\A\s+/, "") }, "```\n", *rest]
      end
      lines.join.rstrip
    end

    def strip_hash(comment_text)
      # "# foo" -> "foo", "#foo" -> "foo", "#" -> ""
      comment_text.sub(/\A#\s?/, "")
    end
  end
end
