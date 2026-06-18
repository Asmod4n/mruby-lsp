# frozen_string_literal: true

require "rbconfig"

# The single Ruby entry point behind every user-facing command. The Linux sandbox
# launcher (ext/mruby_lsp_launcher/launcher.c) — and, off Linux, the shell
# pass-through written by the install hook — confines (where it can) and then
# execve's Ruby as:
#
#     ruby -I<gem>/lib -r mruby_lsp/cli \
#          -e 'MrubyLsp::CLI.run(ARGV.shift, ARGV)' -- <role> [args...]
#
# WHY a dispatcher and not three RubyGems binstubs: every declared `executable` is
# a SECOND file per command, sitting in the bindir next to our compiled launcher —
# which RubyGems then collides with on install and orphans on uninstall, and which
# the launcher would have to PATH-search for. Instead the launcher bakes in the
# Ruby interpreter + this gem's lib dir and runs THIS file directly; `role` (a
# fixed string the launcher passes from its ROLES table — never env, never a
# spoofable argv[0]) selects what to do. One launcher, one dispatcher, no binstubs.
module MrubyLsp
  module CLI
    module_function

    # The `-e` program the launcher / pass-through / child spawns evaluate. Kept in
    # one place so the C launcher, the bundle re-exec, and the setup/update child
    # spawns can't drift apart.
    BOOTSTRAP = "MrubyLsp::CLI.run(ARGV.shift, ARGV)"

    # This gem's lib dir, from THIS file's location (lib/mruby_lsp/cli.rb -> ../..
    # == lib) — the same dir the launcher baked in, so an installed gem and a
    # from-checkout run resolve identically.
    def lib_dir
      File.expand_path("..", __dir__)
    end

    # argv that re-enters this dispatcher for `role` (server / setup / update) as a
    # fresh `ruby` process. Used by the bundle re-exec, by Update#run_setup, and by
    # the server's rebuild-spawn — one bootstrap shared by all of them.
    def child_command(role, *args)
      [RbConfig.ruby, "-I", lib_dir, "-r", "mruby_lsp/cli", "-e", BOOTSTRAP,
       "--", role, *args]
    end

    def run(role, argv)
      case role
      when "server"
        run_server(argv)
      when "setup"
        require_relative "setup"
        Setup.run(argv)
      when "update"
        require_relative "update"
        Update.run(argv)
      else
        warn "mruby-lsp: launcher passed an unrecognized role #{role.inspect} " \
             "(expected server, setup, or update)."
        exit 127
      end
    end

    # ── server role ────────────────────────────────────────────────────────────
    def run_server(argv)
      # The editor may launch us via `bundle exec` inside the USER's project, which
      # makes their Gemfile the active bundle. OUR runtime deps (prism, rdoc) are
      # not in it — and the user must not be required to declare our dependencies.
      # Under Ruby 3.4 + Bundler this is fatal: rdoc is no longer an always-available
      # default gem, so `require "rdoc"` raises LoadError.
      #
      # Fix: if we were launched inside a bundle, re-exec ourselves ONCE with the
      # bundler environment stripped (Bundler.with_unbundled_env). The fresh process
      # starts with no active bundle and full access to all installed gems, so our
      # own deps resolve from RubyGems regardless of the workspace's Gemfile. The
      # re-exec stays confined — Landlock/seccomp set by the launcher are inherited.
      if ENV["BUNDLE_GEMFILE"] && !ENV["MRUBY_LSP_UNBUNDLED"]
        begin
          require "bundler"
          Bundler.with_unbundled_env do
            ENV["MRUBY_LSP_UNBUNDLED"] = "1"
            exec(*child_command("server", *argv))
          end
        rescue LoadError
          # No bundler at all — nothing to escape; fall through.
        end
      end

      # Make our own deps available from RubyGems (now outside any bundle). prism is
      # required for core features; rdoc is optional (C doc comments degrade to off).
      %w[prism rdoc].each do |dep|
        begin
          gem dep
        rescue Gem::LoadError
          nil
        end
      end

      require_relative "../mruby_lsp"

      # Sandbox gate, INTERACTIVE case only. When launched from a real terminal and
      # the launcher could not confine us (Linux without Landlock), ask here — before
      # the LSP loop — and abort on no. Under an LSP client (stdin is a pipe, not a
      # tty) the server asks instead via a native window/showMessageRequest dialog
      # once the connection is up (BaseServer#enforce_sandbox_consent). :confined /
      # non-Linux pass straight through. No env var, no flag: the answer is the
      # kernel status plus the user's reply.
      require_relative "sandbox_status"
      if MrubyLsp::SandboxStatus.unconfined? && $stdin.tty?
        warn "mruby-lsp: WARNING — running WITHOUT the filesystem sandbox " \
             "(Landlock is unavailable on this kernel)."
        $stderr.print "Continue without the sandbox? [y/N] "
        answer = ($stdin.gets || "").strip.downcase
        unless %w[y yes].include?(answer)
          warn "mruby-lsp: aborted — no sandbox."
          exit 1
        end
        warn "mruby-lsp: continuing UNSANDBOXED by your consent."
      end

      # MrubyLsp.start reads the workspace from ARGV[0]. When the launcher invokes us
      # via the -e bootstrap, `argv` IS the already-shifted global ARGV, so this is a
      # no-op; doing it unconditionally keeps run_server correct however it's called.
      ARGV.replace(argv)
      MrubyLsp.start
    end
  end
end
