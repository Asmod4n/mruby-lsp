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
  # NO RubyGems binstubs. The three user-facing commands — `mruby-lsp`,
  # `mruby-lsp-setup`, `mruby-lsp-update` — are produced by the install hook
  # below: on Linux the COMPILED sandbox launcher, elsewhere a shell pass-through.
  # One launcher binary dispatches by its own basename, confines (Landlock +
  # seccomp marker), then execve's Ruby on the gem's CLI dispatcher
  # (lib/mruby_lsp/cli.rb), handing it the command's role (server/setup/update).
  # The dispatcher and its setup/update implementations ship as ordinary lib/
  # files (via spec.files), not as executables, so there is no second binary per
  # command and nothing for RubyGems to collide with on install or orphan on
  # uninstall. Confinement: see docs/design/SANDBOX-CROSSPLATFORM.md.
  spec.executables = []

  # Install-time hook: (1) records the gem's install location in
  # ~/.local/share/mruby-lsp/install.json (passwd-home, env-free) so the VS Code
  # extension finds the command without the user editing PATH; (2) builds the
  # sandbox launcher (Linux, static) + the mruby-lsp-nonet build-phase net seal
  # and drops them in the install's executable dir under all three names. Non-Linux
  # hosts skip the compile and ship a pass-through that execs Ruby on the script.
  #
  # The second extension is the stage-2 Landlock READ wall (MrubyLsp::Landlock).
  # The launcher confines writes/exec BEFORE Ruby; this ext lets the SERVER narrow
  # READS to the project once it learns the workspace from the LSP `initialize`
  # (the only spec-portable source). Built like any CRuby ext; if the kernel
  # headers don't name Landlock, it compiles to a stub that defines nothing, so
  # the server degrades exactly as on an old kernel / macOS / Windows.
  spec.extensions = [
    "ext/mruby_lsp_install/extconf.rb",
    "ext/mruby_lsp_landlock/extconf.rb",
  ]

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
