# frozen_string_literal: true

require_relative "build_discovery"
require_relative "reflector"
require_relative "clangd_client"
require_relative "c_type_resolver"
require_relative "completion"
require_relative "definition"
require_relative "document_symbol"
require_relative "folding_range"
require_relative "selection_range"
require_relative "document_highlight"
require_relative "workspace_symbol"
require_relative "references"
require_relative "rename"
require_relative "signature_help"
require_relative "document_link"
require_relative "code_lens"
require_relative "code_action"
require_relative "inlay_hint"
require_relative "diagnostic"
require_relative "formatting"
require_relative "semantic_tokens"
require_relative "type_hierarchy"
require_relative "hover"
require_relative "evaluatable"
require_relative "buffer_harvester"
require_relative "test_harvester"

module MrubyLsp
  # Concrete server. BaseServer owns the wire and document lifecycle.
  # Server owns the index and the language features.
  class Server < BaseServer
    def initialize(*args, workspace_arg: nil, **kwargs)
      announce_version
      super(*args, **kwargs)
      @index = Index.new
      # Explicit workspace from the launch argument (canonicalized to match how
      # mruby-lsp-setup derives the cache key). nil if not passed — we then fall
      # back to the initialize rootUri, then cwd, so generic LSP clients (no
      # custom args) still work.
      @workspace = workspace_arg && File.expand_path(workspace_arg)
      @rebuilding = false
    end

    private

    # Resolve the workspace root, editor-agnostic, in priority order:
    #   1. the launch argument (our extension passes it)            -> already set
    #   2. the initialize rootUri / workspaceFolders (standard LSP)
    #   3. the server's working directory (clients usually cwd into the project)
    # All canonicalized via File.expand_path so the cache key matches setup's.
    def lsp_initialize(msg)
      unless @workspace
        root = msg.dig(:params, :workspaceFolders, 0, :uri) || msg.dig(:params, :rootUri)
        path = root&.sub(%r{\Afile://}, "")
        @workspace = File.expand_path(path || Dir.pwd)
      end
      super
    end

    def lsp_initialized(msg)
      enforce_sandbox_consent # gate BEFORE any workspace work; may terminate
      apply_read_wall         # stage-2 Landlock: now that @workspace is known
      populate_index
      nil
    end

    # Stage-2 Landlock (see ext/mruby_lsp_landlock + the launcher header). The
    # launcher confined WRITES/EXEC before Ruby but left READS open, because the
    # workspace is only knowable from the LSP `initialize` (which arrives after
    # exec) and Landlock layers can only tighten. Now that @workspace is resolved
    # we stack a layer that allows READS only beneath the project + the dirs Ruby
    # itself needs, denying every read outside. Inherited by the rebuild child.
    #
    # Gated on SandboxStatus.confined?: the seccomp marker means stage-1 Landlock
    # succeeded, i.e. the kernel HAS Landlock, so the ext (built on the same host)
    # is present and restrict_reads will work. When unconfined the user already
    # consented to run without the wall, so we don't attempt (and don't raise).
    def apply_read_wall
      require_relative "sandbox_status"
      return unless SandboxStatus.confined?

      begin
        require "mruby_lsp_landlock"
      rescue LoadError
        # ext not built (e.g. from-checkout run); nothing to raise here.
      end
      unless defined?(MrubyLsp::Landlock) && MrubyLsp::Landlock.respond_to?(:restrict_reads)
        warn "mruby-lsp: stage-1 confined but the stage-2 Landlock ext is " \
             "unavailable — READS are NOT walled. Reinstall so " \
             "ext/mruby_lsp_landlock builds."
        return
      end

      reads = read_allowlist
      # Let a real failure SURFACE (no silent rescue): when stage-1 confined us,
      # restrict_reads must succeed; if it doesn't, that is a bug worth seeing.
      MrubyLsp::Landlock.restrict_reads(reads)
    end

    # The READ set the stage-2 wall grants (on top of the system/Ruby base the C
    # ext bakes in): the project, its mruby checkout + build cache, our state
    # dirs, the Ruby install prefix, and every gem dir — everything the server and
    # the (inherited) rebuild build legitimately read.
    def read_allowlist
      require_relative "build_discovery"
      bd = MrubyLsp::Discovery::BuildDiscovery
      paths = []
      if @workspace
        paths << @workspace
        paths << (bd.resolve_mruby_root(@workspace) rescue nil)
        paths << (bd.cache_dir(@workspace) rescue nil)
      end
      home = (bd.home_dir rescue Dir.home)
      paths << File.join(home, ".cache", "mruby-lsp")
      paths << File.join(home, ".local", "share", "mruby-lsp")
      paths << RbConfig::CONFIG["prefix"]
      paths.concat(Gem.path)
      paths << Gem.dir << Gem.user_dir
      paths.compact.uniq
    end

    # ── rebuild on save (standing consent only) ──────────────────────────────
    #
    # Consent state machine (per-workspace, default OFF):
    #   no consent       -> never build; saving does nothing here
    #   standing consent -> "rebuild_on_save": true in .mruby-lsp/config.json;
    #                       saving a build-relevant file triggers the SAME
    #                       pipeline as mruby-lsp-setup (no privileged path)
    # Missing/stale artifacts never trigger a build by themselves.
    def text_document_did_save(msg)
      super
      return nil unless rebuild_on_save?

      uri = msg.dig(:params, :textDocument, :uri).to_s
      return nil unless build_relevant?(uri)

      rebuild_and_reindex
      nil
    end

    def rebuild_on_save?
      return false unless @workspace

      # SECURITY: consent to RUN A BUILD on save must come from the user's own
      # state store (~/.local/share), keyed by workspace — never from a file in
      # the workspace, which a hostile repo controls and could use to make merely
      # opening it execute their build.
      require_relative "build_discovery"
      config = MrubyLsp::Discovery::BuildDiscovery.config_store_path(@workspace)
      return false unless File.file?(config)

      JSON.parse(File.read(config))["rebuild_on_save"] == true
    end

    # A save is build-relevant if it changes what the compiled VM would contain:
    # mruby Ruby source, C source/headers, gem specs, or the build config itself.
    def build_relevant?(uri)
      path = uri.sub(%r{\Afile://}, "")
      base = File.basename(path)
      return true if base == "mrbgem.rake"
      return true if base.end_with?("build_config.rb")

      ext = File.extname(path)
      %w[.rb .c .h .cpp .hpp].include?(ext)
    end

    # The CURRENT reflect_so for this workspace. The build artifacts live in the
    # gem's cache (~/.cache/mruby-lsp/<project-key>) — never in the user's
    # project. We derive the cache path by hashing the workspace exactly the way
    # mruby-lsp-setup does, then read reflect_so from that cache's paths.env.
    # (The .so is content-hash versioned, so a rebuilt VM has a new path and
    # `require` loads it fresh.) Env var is a fallback for ad-hoc runs.
    def current_reflect_so
      if @workspace
        require_relative "build_discovery"
        env_file = File.join(MrubyLsp::Discovery::BuildDiscovery.cache_dir(@workspace), "paths.env")
        if File.file?(env_file)
          line = File.readlines(env_file).find { |l| l.start_with?("reflect_so=") }
          return line.split("=", 2).last.strip if line
        end
      end
      ENV["MRUBY_REFLECT_SO"]
    end

    # Re-run the setup pipeline (idempotent; rake redoes only what changed),
    # then re-reflect into a FRESH index and swap it in atomically — requests
    # arriving during the rebuild keep being served by the old index.
    def rebuild_and_reindex
      return if @rebuilding

      @rebuilding = true
      # Re-run setup in a CHILD via the one shared bootstrap (CLI.child_command —
      # `ruby -I lib -r mruby_lsp/cli -e … -- setup <ws>`). This server is already
      # confined, so the child inherits the wall + scrubbed env. stdout/stderr go to
      # /dev/null: setup chatters on stdout, and OUR stdout is the LSP framing
      # channel — letting it leak would corrupt the protocol stream.
      require_relative "cli"
      ok = system(*MrubyLsp::CLI.child_command("setup", @workspace),
                  out: File::NULL, err: File::NULL)
      return unless ok

      fresh = Index.new
      reflector = Reflector.open(current_reflect_so, mruby_root: MrubyLsp::Discovery::BuildDiscovery.resolve_mruby_root(@workspace))
      return unless reflector

      begin
        reflector.populate(fresh)
      ensure
        reflector.close
      end
      attach_ctype_resolver(fresh)

      @mutex.synchronize do
        # carry the live buffer overlay over — open tabs stay authoritative
        @index.transfer_buffers_to(fresh)
        @index = fresh
      end
      # re-harvest open documents into the new index's buffer layer
      @store.each_uri { |uri| refresh_buffer(uri) } if @store.respond_to?(:each_uri)
    ensure
      @rebuilding = false
    end

    def text_document_did_open(msg)
      super
      refresh_buffer(msg[:params][:textDocument][:uri])
      nil
    end

    def text_document_did_change(msg)
      super
      refresh_buffer(msg[:params][:textDocument][:uri])
      nil
    end

    def text_document_did_close(msg)
      uri = msg[:params][:textDocument][:uri]
      super
      @mutex.synchronize { @index.clear_buffer(uri) }
      nil
    end

    # Harvest the open document's definitions into the index's buffer layer.
    # order_key ranks the uri in mruby's compile order (from the sidecar, when
    # available); a uri not in any known gem sorts last (newest tab wins).
    def refresh_buffer(uri)
      doc = @mutex.synchronize { @store.get(uri) }
      return unless doc

      entries = BufferHarvester.harvest(uri, doc.ast.value, doc.text, @index)
      ivar_schema = BufferHarvester.ivar_schemas(doc.ast.value)
      order_key = @compile_order ? @compile_order.key_for(uri) : [Float::INFINITY, uri]
      @mutex.synchronize do
        @index.set_buffer(uri, entries, order_key)
        @index.set_buffer_ivar_schema(uri, ivar_schema)
      end
      TypeHierarchy.register(doc)
    end

    def announce_version
      require_relative "version"
      warn "mruby-lsp server #{MrubyLsp::VERSION} (#{$PROGRAM_NAME})"
    end

    def text_document_completion(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return { isIncomplete: false, items: [] } unless doc

      # isIncomplete: the list is PREFIX-DEPENDENT (methods are filtered by the
      # typed prefix, and block/keyword scaffolds are only emitted for a non-empty
      # prefix). Saying it's complete makes a client cache the trigger-time list
      # (empty prefix at the `.`, no scaffolds) and filter it client-side, so the
      # scaffolds never appear until a fresh request. True = re-ask as you type.
      { isIncomplete: true, items: Completion.items(doc, position, @index, snippets: snippet_support?) }
    end

    # Does the client render snippet completion items (tab-stop templates)? A
    # CLIENT capability — emitting insertTextFormat:2 to a client without it
    # inserts the raw `${1:..}`, so keyword scaffolds are gated on it.
    def snippet_support?
      @client_capabilities.to_h.dig(:textDocument, :completion, :completionItem, :snippetSupport) ? true : false
    end

    # Lazy per-item documentation, ruby-lsp semantics (CompletionResolve):
    # documentation = the full hover-style markdown (title + Definitions +
    # comments) for the item's resolved entries, capped at 10 like ruby-lsp's
    # MAX_DOCUMENTATION_ENTRIES. No fields other than documentation change.
    def completion_item_resolve(msg)
      item = msg[:params]
      name = item.dig(:data, :name)
      return item unless name

      entries = @index.definitions(name).first(10).map { |e| @index.enrich(e) }
      return item if entries.empty?

      # Same Overrides line hover shows: this definition's super-walk (owner's
      # chain, the shown definition excluded, shadowed VM twin included).
      sep = name.include?("#") ? "#" : "."
      owner, meth = name.split(sep, 2)
      chain = @index.method_chain(owner, meth, singleton: sep == ".")
      overrides = Hover.override_chain(entries, chain, @index)

      doc = Hover.render(entries, overrides)
      item[:documentation] = { kind: "markdown", value: doc } if doc
      item
    end

    def text_document_hover(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc

      Hover.response(doc, position, @index)
    end

    # Custom: the expression VS Code should hand to the debugger when you hover
    # the source mid-debug. Prism finds the real expression bounds so a hover
    # inside a string literal yields the whole literal, never a `"hello` shard.
    def mruby_lsp_evaluatable_expression(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc

      Evaluatable.response(doc, position)
    end

    def text_document_definition(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc

      locs = Definition.locations(doc, position, @index)
      locs.empty? ? nil : locs
    end

    def text_document_document_symbol(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      DocumentSymbol.response(doc)
    end

    def text_document_folding_range(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      FoldingRange.response(doc)
    end

    def text_document_selection_range(msg)
      uri = msg[:params][:textDocument][:uri]
      positions = msg[:params][:positions] || []
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      SelectionRange.response(doc, positions)
    end

    def text_document_document_highlight(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      DocumentHighlight.response(doc, position)
    end

    def workspace_symbol(msg)
      query = msg[:params] && msg[:params][:query]
      idx = @mutex.synchronize { @index }
      WorkspaceSymbol.response(idx, query.to_s)
    end

    def text_document_references(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      ctx = msg[:params][:context] || {}
      include_decl = ctx.fetch(:includeDeclaration, true)
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      References.response(doc, position, include_decl)
    end

    def text_document_prepare_rename(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc
      Rename.prepare(doc, position)
    end

    def text_document_rename(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      new_name = msg[:params][:newName]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc
      Rename.response(doc, position, new_name)
    end

    def text_document_signature_help(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc
      SignatureHelp.response(doc, position, @index)
    end

    def text_document_document_link(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      DocumentLink.response(doc)
    end

    def text_document_code_lens(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      CodeLens.response(doc)
    end

    def text_document_code_action(msg)
      uri = msg[:params][:textDocument][:uri]
      range = msg[:params][:range]
      context = msg[:params][:context]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      CodeAction.response(doc, range, context, uri)
    end

    def text_document_inlay_hint(msg)
      uri = msg[:params][:textDocument][:uri]
      range = msg[:params][:range]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      InlayHint.response(doc, range)
    end

    def text_document_diagnostic(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return { kind: "full", items: [] } unless doc
      Diagnostic.response(doc)
    end

    def text_document_range_formatting(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc
      Formatting.range(doc, msg[:params][:range], msg[:params][:options])
    end

    def text_document_on_type_formatting(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return [] unless doc
      Formatting.on_type(doc, msg[:params][:position], msg[:params][:ch], msg[:params][:options])
    end

    def text_document_semantic_tokens_full(msg)
      uri = msg[:params][:textDocument][:uri]
      doc = @mutex.synchronize { @store.get(uri) }
      return { data: [] } unless doc
      SemanticTokens.response(doc, special_methods)
    end

    def text_document_semantic_tokens_range(msg)
      uri = msg[:params][:textDocument][:uri]
      range = msg[:params][:range]
      doc = @mutex.synchronize { @store.get(uri) }
      return { data: [] } unless doc
      SemanticTokens.response_range(doc, special_methods, range)
    end

    # The set of mruby built-in methods (TextMate already colors these, so we
    # skip a semantic token), sourced from the LIVE VM at populate (Kernel +
    # Module own methods, public AND private) and carried on the index. Empty
    # when no VM is loaded (degraded) — which just means no suppression.
    def special_methods
      @mutex.synchronize { @index.special_methods } || Set.new
    end

    def text_document_prepare_type_hierarchy(msg)
      uri = msg[:params][:textDocument][:uri]
      position = msg[:params][:position]
      doc = @mutex.synchronize { @store.get(uri) }
      return nil unless doc
      TypeHierarchy.prepare(doc, position, @index)
    end

    def type_hierarchy_supertypes(msg)
      item = msg[:params][:item]
      TypeHierarchy.supertypes(item, @index)
    end

    def type_hierarchy_subtypes(msg)
      item = msg[:params][:item]
      TypeHierarchy.subtypes(item, @index)
    end

    # T3.2 — populate the index from the live mruby VM. The reflect_so is the
    # source of truth; if it isn't available, the index stays empty (no CRuby
    # fallback, ever).
    def populate_index
      so = current_reflect_so

      # Guard: refuse to reflect an mruby build that segfaults on
      # Method#source_location for aliased C methods (mruby/mruby#6879). That is
      # a C-level crash we cannot rescue, so we detect it in a forked probe and
      # skip the populate walk instead of dying. Buffer (Prism) features keep
      # working with an empty VM index; the user gets the exact fix.
      if so && !Reflector.alias_safe?(so)
        show_message(
          "mruby-lsp: your mruby build crashes on source_location for aliased " \
          "C methods (mruby/mruby#6879), so VM reflection is disabled to avoid " \
          "a crash. Fix: update mruby past the #6879 fix, then run `rake " \
          "deep_clean` in your mruby checkout and re-run: " \
          "mruby-lsp-setup #{@workspace}",
          type: 1,
        )
        return
      end

      reflector = so && Reflector.open(so, mruby_root: MrubyLsp::Discovery::BuildDiscovery.resolve_mruby_root(@workspace))
      unless reflector
        # Not built yet (no reflect_so in this workspace's cache). Tell the user
        # in an editor-agnostic way: a plain window/showMessage that any LSP
        # client can surface, plus the exact command to fix it. The server keeps
        # running with an empty index rather than failing.
        show_message(
          "mruby-lsp: this project isn't built yet. Run: mruby-lsp-setup #{@workspace}",
          type: 2,
        )
        return
      end

      begin
        reflector.populate(@index)
      ensure
        reflector.close
      end
      harvest_test_types(MrubyLsp::Discovery::BuildDiscovery.resolve_mruby_root(@workspace))
      attach_ctype_resolver(@index)
    end

    # Stage 4: mine return types from the workspace's test suite and merge them
    # into the index. mruby's tests run against the real VM, so a passing
    # assertion is a VM-true return type -- it fills exactly the methods clangd
    # cannot infer (io_read -> String?). Reads the core + bundled-mgem tests under
    # the mruby root. Unreadable/binary files are skipped; a parse failure is
    # handled inside the harvester. No VM call, so it is cheap and crash-free.
    def harvest_test_types(mruby_root)
      return unless mruby_root && Dir.exist?(mruby_root)
      files = Dir.glob(File.join(mruby_root, "test", "**", "*.rb")) +
              Dir.glob(File.join(mruby_root, "mrbgems", "**", "test", "**", "*.rb"))
      sources = files.uniq.filter_map do |f|
        next unless File.file?(f) && File.readable?(f)
        s = File.read(f, encoding: "BINARY").force_encoding("UTF-8")
        s if s.valid_encoding?
      end
      @index.merge_test_types(TestHarvester.harvest(sources))
    end

    # ---- Stage 3 (C return types via clangd), lazy + degrade-safe ------------

    # One managed clangd for the server's lifetime (it re-reads compile_commands
    # on change, so it survives rebuilds). nil if clangd is absent or the build
    # has no DB yet -> Stage 3 simply off. clangd idles until a C type is first
    # requested (parse is per-file, on demand), so this costs ~nothing at start.
    def clangd_client
      return @clangd if defined?(@clangd)
      @clangd = build_clangd
    end

    def build_clangd
      build_dir = paths_env_value("mruby_build")
      return nil unless build_dir
      db = File.join(build_dir, "compile_commands.json")
      return nil unless File.file?(db)
      clangd = resolve_clangd
      return nil unless clangd
      ClangdClient.start(compile_commands_dir: build_dir,
                         query_driver: clangd_query_driver(db), clangd: clangd)
    end

    # clangd is packaged inconsistently across distros: a plain `clangd`
    # (Arch, Fedora's clang-tools-extra), a VERSIONED `clangd-22` with no
    # unversioned alias (openSUSE, Debian/Ubuntu), or only under an LLVM libdir
    # / Homebrew prefix. Find one WITHOUT making the user symlink — else Stage 3
    # (C return types) silently never turns on. Order: explicit override, then
    # PATH, then the highest versioned clangd-N, then clang's co-located sibling,
    # then well-known dirs. nil -> Stage 3 stays off (degrade-safe).
    def resolve_clangd
      ext = RbConfig::CONFIG["EXEEXT"]

      override = ENV["MRUBY_LSP_CLANGD"]
      if override && !override.empty?
        return override if override.include?("/") ? File.executable?(override) : which(override)
      end

      base = "clangd#{ext}"
      return base if which(base)

      # Highest versioned binary on PATH wins (clangd-22 beats clangd-20).
      40.downto(12) do |n|
        name = "clangd-#{n}#{ext}"
        return name if which(name)
      end

      # clang can report a clangd sitting in its own toolchain bindir.
      cc = which("clang#{ext}")
      if cc
        out = begin
          `#{cc} -print-prog-name=clangd 2>/dev/null`.strip
        rescue StandardError
          ""
        end
        return out if !out.empty? && out.include?("/") && File.executable?(out)
      end

      # Well-known install dirs (LLVM libdir, Homebrew); highest LLVM-N first.
      (Dir.glob("/usr/lib/llvm-*/bin/clangd") +
       Dir.glob("/usr/lib64/llvm-*/bin/clangd") +
       ["/opt/homebrew/opt/llvm/bin/clangd", "/usr/local/opt/llvm/bin/clangd"])
        .select { |p| File.executable?(p) && !File.directory?(p) }
        .max_by { |p| p[%r{llvm-(\d+)}, 1].to_i }
    end

    # clangd --query-driver wants the build compiler's path so it can adopt that
    # toolchain's system includes. Take the DB's compiler, resolved on PATH.
    def clangd_query_driver(db)
      first = JSON.parse(File.read(db)).first or return nil
      cmd = first["arguments"]&.first || first["command"].to_s.split.first
      return nil unless cmd
      cmd.include?("/") ? cmd : which(cmd) || cmd
    end

    def which(cmd)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        p = File.join(dir, cmd)
        return p if File.executable?(p) && !File.directory?(p)
      end
      nil
    end

    # Fresh CTypeResolver per index generation (cheap wrapper + memo); the clangd
    # process itself is shared. On rebuild a fresh index gets a fresh resolver, so
    # C types re-resolve against the new build -- dynamic, no stale memo survives.
    def attach_ctype_resolver(index)
      c = clangd_client
      index.ctype_resolver = CTypeResolver.new(c) if c
    end

    # Read a key from this workspace's cache paths.env (build_dir, mruby_build…).
    def paths_env_value(key)
      return nil unless @workspace
      env_file = File.join(MrubyLsp::Discovery::BuildDiscovery.cache_dir(@workspace), "paths.env")
      return nil unless File.file?(env_file)
      line = File.readlines(env_file).find { |l| l.start_with?("#{key}=") }
      line&.split("=", 2)&.last&.strip
    end
  end
end
