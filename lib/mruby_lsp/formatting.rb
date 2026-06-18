# frozen_string_literal: true

module MrubyLsp
  # textDocument/rangeFormatting + onTypeFormatting. ruby-lsp delegates to an
  # external formatter (RuboCop / syntax_tree) resolved through the project
  # bundle; with none configured it returns null for range formatting and [] for
  # on-type (verified against the running server). mruby-lsp does not bundle a
  # Ruby formatter, so the conformant result is the same: null / []. Capabilities
  # are advertised with ruby-lsp's exact onType trigger set so the contract
  # matches; if a formatter is wired in later, edits are produced here.
  module Formatting
    module_function

    ON_TYPE_TRIGGERS = ["{", "\n", "|", "d"].freeze

    def range(_document, _range, _options)
      nil
    end

    def on_type(_document, _position, _ch, _options)
      []
    end
  end
end
