# frozen_string_literal: true

require "json"
require_relative "mruby_lsp/index"
require_relative "mruby_lsp/document_store"
require_relative "mruby_lsp/base_server"
require_relative "mruby_lsp/version"

module MrubyLsp

  def self.start
    # An LSP client may pass the workspace dir as the first argument (our
    # editor extension does). Editor-agnostic: clients that can't pass args
    # still work — the server falls back to the initialize rootUri, then cwd.
    Server.new(workspace_arg: ARGV[0]).start
  end
end

require_relative "mruby_lsp/server"
