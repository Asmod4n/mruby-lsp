# frozen_string_literal: true

module MrubyLsp
  # textDocument/codeLens — ruby-lsp emits Run/Debug/Run-in-terminal lenses on
  # test classes/methods, but ONLY when a known test framework (minitest,
  # test-unit, rspec) is resolved through the project's Bundler environment, and
  # those lenses invoke ruby-lsp's OWN client-side commands. Verified against the
  # running server: with no test framework in the bundle it returns [].
  #
  # mruby-lsp does not ship ruby-lsp's test-runner client commands, and mruby
  # projects don't carry that bundle, so the conformant result is always [] —
  # exactly what ruby-lsp returns in this environment. If/when an mruby test
  # convention + client commands exist, lenses get emitted here.
  module CodeLens
    module_function

    def response(_document)
      []
    end
  end
end
