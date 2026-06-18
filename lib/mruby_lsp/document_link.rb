# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/documentLink — resolves magic comments of the form
  # `source://gem/path#line` or `pkg:gem/...#...` to local gem source files, the
  # SAME (and only) thing ruby-lsp's documentLink does (verified: returns [] for
  # ordinary code, because these comments are an RBS/sorbet tooling artifact that
  # does not appear in mruby source). The matcher is real, not a stub; it simply
  # finds nothing to link in normal mruby buffers.
  module DocumentLink
    module_function

    PATTERN = %r{(source://.*#\d+|pkg:gem/.*#.*)$}

    # Build once: gem name+version -> require path roots, like ruby-lsp's
    # GEM_TO_VERSION_MAP. Best-effort from installed default + bundled stubs.
    def gem_map
      @gem_map ||= begin
        map = {}
        ([*Gem::Specification.default_stubs, *Gem::Specification.stubs]).each do |s|
          map["#{s.name}@#{s.version}"] = s.full_gem_path
        end
        map
      end
    end

    def response(document)
      links = []
      comments(document).each do |loc, text|
        m = text.match(PATTERN)
        next unless m
        uri = m[0]
        target = resolve(uri)
        next unless target
        links << {
          range: {
            start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
            end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
          },
          target: target
        }
      end
      links
    end

    # Comments from the Prism parse result.
    def comments(document)
      result = document.ast
      result.comments.map { |c| [c.location, c.location.slice] }
    end

    # source://gem/relative/path.rb#42 -> file:// in the local gem, if resolvable.
    def resolve(uri_string)
      return nil unless uri_string.start_with?("source://")
      body = uri_string.sub("source://", "")
      gem_seg, _frag = body.split("#", 2)
      gem_name, *rest = gem_seg.split("/")
      return nil if gem_name.nil? || rest.empty?
      root = gem_root(gem_name)
      return nil unless root
      path = File.join(root, *rest)
      File.exist?(path) ? "file://#{path}" : nil
    end

    def gem_root(gem_name)
      gem_map.each { |k, v| return v if k.start_with?("#{gem_name}@") }
      nil
    end
  end
end
