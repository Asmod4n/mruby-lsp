# frozen_string_literal: true

require "prism"

module MrubyLsp
  # textDocument/diagnostic — pull diagnostics from the buffer's Prism parse,
  # matching ruby-lsp's shape (verified against the running server):
  #   { kind: "full", items: [ { range, severity, source: "Prism", message } ] }
  # errors -> severity 1, warnings -> severity 2. (ruby-lsp also runs RuboCop
  # when available; mruby projects don't carry that bundle, so Prism diagnostics
  # are the conformant set — same source tag, same shape.)
  module Diagnostic
    module_function

    ERROR = 1
    WARNING = 2

    def response(document)
      result = document.ast
      items = []
      collect(result.errors, ERROR, items)
      collect(result.warnings, WARNING, items)
      { kind: "full", items: items }
    end

    def collect(diags, severity, items)
      diags.each do |d|
        loc = d.location
        items << {
          range: {
            start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
            end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
          },
          severity: severity,
          source: "Prism",
          message: d.message
        }
      end
    end
  end
end
