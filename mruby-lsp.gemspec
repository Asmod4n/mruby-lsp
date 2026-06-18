# frozen_string_literal: true

require_relative "lib/mruby_lsp/version"

Gem::Specification.new do |spec|
  spec.name = "mruby-lsp"
  spec.version = MrubyLsp::VERSION
  spec.authors = ["mruby-lsp contributors"]
  spec.email = [""]
  spec.summary = "Language Server Protocol for mruby"
  spec.description = "A standalone LSP server for mruby, with live VM reflection as the source of truth"
  spec.homepage = "https://github.com/Asmod4n/mruby-lsp"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files =
    Dir.glob("lib/**/*.rb") +
    Dir.glob("bin/*") +
    Dir.glob("share/*") +
    Dir.glob("ext/**/*.{rb,c,h}") +
    # Vendored internal gem (value_bridge): ship its source so the mruby build
    # (mgem face) and the reflect ext (CRuby leg) find it inside the installed
    # gem. It is ALSO installed as its own gem by `rake install` to satisfy the
    # add_dependency below -- same single source, two consumers.
    Dir.glob("vendor/value_bridge/**/*").select { |f| File.file?(f) } +
    # Same model for mruby-platform: ship its source so the wrapper's
    # `conf.gem gemdir: vendor/mruby-platform` resolves in the installed gem.
    Dir.glob("vendor/mruby-platform/**/*").select { |f| File.file?(f) } +
    # Local mgems shipped INSIDE the gem so the wrapper's `conf.gem gemdir:`
    # (share/wrapper_build_config.rb, relative to share/ -> ../gems/<name>)
    # resolves in the installed gem, not just dev-from-repo. mruby-irep-reflect
    # = irep return-type reflection (Stage 2); mruby-lsp-ccj = compile_commands
    # emitter for clangd (Stage 3). Same model as value_bridge: source ships,
    # the wrapper points gemdir: at it. Without this the packaged gem builds
    # fail: "Can't find .../gems/mruby-irep-reflect/mrbgem.rake".
    Dir.glob("gems/**/*").select { |f| File.file?(f) } +
    ["README.md", "LICENSE"]

  spec.bindir = "bin"
  # The three names editors/users call — `mruby-lsp`, `mruby-lsp-setup`,
  # `mruby-lsp-update` — are each the COMPILED Linux sandbox launcher, NOT Ruby
  # binstubs. The install hook below builds the launcher from
  # ext/mruby_lsp_launcher/launcher.c and writes it to the gem's bindir under all
  # three names; one binary, it dispatches by its own basename to the matching
  # impl and confinement profile. The Ruby entry points are shipped as the
  # `-server` / `-setup-impl` / `-update-impl` siblings and execve'd by the
  # launcher. Confinement is mandatory; see docs/design/SANDBOX-CROSSPLATFORM.md.
  spec.executables = ["mruby-lsp-server", "mruby-lsp-setup-impl", "mruby-lsp-update-impl"]

  # Install-time hook: (1) records the gem's install location in
  # $XDG_DATA_HOME/mruby-lsp/install.json so the VS Code extension can find the
  # server without the user editing PATH; (2) compiles the sandbox launcher
  # (Linux) and drops it into the gem's bindir as `mruby-lsp`. Non-Linux hosts
  # skip step 2 and ship a pass-through wrapper that execs the Ruby server.
  spec.extensions = ["ext/mruby_lsp_install/extconf.rb"]

  # >= 1.9.0: the features lean on the code-units position API
  # (start_code_units_column / cached_*_code_units_*) for correct UTF-16 columns;
  # older prism lacks it and raises NoMethodError at first edit. 1.9.0 is also the
  # version vendored + tested (editors/vscode/vendor/gems/manifest.json).
  spec.add_dependency "prism", ">= 1.9.0"
  spec.add_dependency "language_server-protocol", "~> 3.17"
  spec.add_dependency "rbs", ">= 3.0"
  spec.add_dependency "value_bridge"

  spec.post_install_message = <<~MSG
    mruby-lsp installed.

    Install the VS Code extension to use it (from the gem's editors/vscode):
        rake vscode:install

    Then open an mruby project. If it isn't built yet, the extension offers to
    build it; or run `mruby-lsp-setup <project-path>` yourself.
  MSG
end
