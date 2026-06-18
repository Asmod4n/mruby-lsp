# frozen_string_literal: true

require "json"
require "language_server-protocol"
require_relative "document_store"

require_relative "semantic_tokens"

module MrubyLsp
  class BaseServer
    def initialize(stdin = $stdin, stdout = $stdout)
      @stdin = stdin
      @stdout = stdout
      @reader = LanguageServer::Protocol::Transport::Io::Reader.new(@stdin)
      @writer = LanguageServer::Protocol::Transport::Io::Writer.new(@stdout)
      @incoming_queue = Queue.new
      @outgoing_queue = Queue.new
      @store = DocumentStore.new
      @mutex = Mutex.new
      @shutdown = false
      @terminating = false
      # Server-initiated requests (e.g. window/showMessageRequest): id -> Queue,
      # so the reader thread can hand the client's reply back to the waiter.
      @server_requests = {}
      @sr_mutex = Mutex.new
      @sr_seq = 0
      # Per-request lifecycle logging to stderr, off unless the editor turns on
      # tracing (mrubyLsp.trace.server != off sets MRUBY_LSP_TRACE).
      @trace = !(ENV["MRUBY_LSP_TRACE"] || "").empty?
    end

    # Three threads, one rule: the reader thread must NEVER block on real work.
    #
    #   reader (this/main thread) — reads frames, triages them. Lifecycle
    #     messages (shutdown/exit) are handled INLINE here, so they can never
    #     queue behind a long-running handler. Everything else is handed to the
    #     worker. Because this thread owns termination, the editor's
    #     client.stop() (which it awaits on window-close/reload) always gets its
    #     shutdown response and the process always exits — even mid-build.
    #   worker — pops normal messages and dispatches handlers. This is the ONLY
    #     thread allowed to block (populate, rebuild, addr2line, etc.).
    #   writer — drains the outgoing queue to stdout.
    def start
      @worker = Thread.new { process_messages }
      @writer_thread = Thread.new { write_messages }
      read_messages
    end

    private

    # Lifecycle messages handled in the reader thread, never queued.
    URGENT_METHODS = %w[shutdown exit].freeze

    def read_messages
      @reader.read do |msg|
        if msg[:id] && msg[:method].nil? && (msg.key?(:result) || msg.key?(:error))
          route_server_response(msg) # a reply to one of OUR requests
        elsif URGENT_METHODS.include?(msg[:method])
          handle_urgent(msg) # may not return: exit terminates here
        else
          @incoming_queue << msg
        end
      end
    rescue ClosedQueueError
      # We are already terminating; the worker queue was closed under us.
    ensure
      # stdin closed means the client is gone (window closed/reloaded). Tear
      # everything down even if the worker is wedged in a blocking build.
      terminate(0)
    end

    # shutdown and exit, serviced off the critical path so a blocked worker can
    # never delay them.
    def handle_urgent(msg)
      case msg[:method]
      when "shutdown"
        # A request: it MUST get a response. Route it through the writer thread
        # (also independent of the worker) so the client's stop() unblocks.
        @shutdown = true
        enqueue({ jsonrpc: "2.0", id: msg[:id], result: nil })
      when "exit"
        terminate(@shutdown ? 0 : 1)
      end
    end

    # Cross-platform clean shutdown. Deliberately NOT OS signals (SIGTERM/
    # SIGKILL differ on Windows). The portable primitives:
    #   1. Queue#clear/#close — drop pending work and wake the worker's blocked
    #      `pop` with nil, so a worker that is merely WAITING stops cleanly.
    #   2. Thread#join(timeout) — give the worker a short, bounded chance to
    #      finish the item it is on; bounded so a wedged worker can't stall us.
    #   3. flush + exit!(code) — guarantee the process dies even if the worker
    #      is stuck in a blocking native call (system()/fork/addr2line). _exit
    #      behaves identically on every platform. We flush first so the shutdown
    #      response actually reaches the client before we go.
    def terminate(code)
      return if @terminating

      @terminating = true
      @incoming_queue.clear
      @incoming_queue.close
      @worker&.join(0.5)
      @outgoing_queue.close # writer drains what's left (incl. shutdown reply)
      @writer_thread&.join(0.3)
      @stdout.flush
    ensure
      exit!(code)
    end

    def write_messages
      while (msg = @outgoing_queue.pop)
        @writer.write(msg)
      end
    rescue ClosedQueueError
      # Terminating; drain loop ends.
    end

    def process_messages
      while (msg = @incoming_queue.pop)
        dispatch(msg)
      end
    rescue ClosedQueueError
      # Terminating; queue closed.
    end

    def dispatch(msg)
      id     = msg[:id]
      method = msg[:method]
      return unless method

      handler = METHOD_MAP[method]
      unless handler
        # Unknown request — send method not found only for requests (have id)
        reply(id, error: { code: -32601, message: "Method not found: #{method}" }) if id
        return
      end

      begin
        warn "[mruby-lsp] >> #{method} id=#{id.inspect} (#{request_context(msg)})" if @trace
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @trace
        result = with_timeout(request_timeout_seconds) { send(handler, msg) }
        if @trace
          dt = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
          size = result.is_a?(Array) ? result.size : (result.is_a?(Hash) && result[:items].is_a?(Array) ? result[:items].size : nil)
          warn "[mruby-lsp] << #{method} id=#{id.inspect} #{dt}ms#{size ? " n=#{size}" : ""}"
        end
      rescue RequestTimeout => e
        # A single request ran past the budget — almost always a reflection or
        # addr2line call wedged on pathological input. Abandon JUST this request
        # so the worker is free for the next one, tell the client (so its peek/
        # jump UI stops spinning), and log it with full context for the output
        # channel. -32800 is LSP's RequestCancelled; the editor treats it as a
        # benign no-result rather than an error popup.
        log_message("timeout: #{method} exceeded #{request_timeout_seconds}s " \
                    "(#{request_context(msg)}) — request abandoned", type: 2)
        reply(id, error: { code: -32800, message: "Request timed out: #{method}" }) if id
        return
      end

      # Notifications (no id) never get a response
      reply(id, result: result) if id
    end

    def reply(id, result: nil, error: nil)
      body = error ? { jsonrpc: "2.0", id: id, error: error }
                    : { jsonrpc: "2.0", id: id, result: result }
      enqueue(body)
    end

    def enqueue(body)
      @outgoing_queue << body
    rescue ClosedQueueError
      nil # terminating; client is gone
    end

    # Send a server-initiated notification (no id; client sends no response).
    def notify(method, params)
      enqueue({ jsonrpc: "2.0", method: method, params: params })
    end

    # window/showMessage — a plain client notification. Widely supported across
    # LSP clients (unlike window/showMessageRequest, the button popup, which many
    # minimal clients ignore). type: 1=Error 2=Warning 3=Info 4=Log.
    def show_message(text, type: 3)
      notify("window/showMessage", { type: type, message: text })
    end

    # window/logMessage — goes to the client's output/log channel (the "mruby-lsp"
    # dropdown in VS Code's Output panel), NOT a popup. The right place for
    # diagnostics like timeouts and handler errors: visible when you look, never
    # in the user's face. Same type scale as show_message.
    def log_message(text, type: 4)
      notify("window/logMessage", { type: type, message: "mruby-lsp: #{text}" })
    end

    # Route a client's reply to one of our server-initiated requests back to the
    # blocked caller (runs on the reader thread; must not block).
    def route_server_response(msg)
      q = @sr_mutex.synchronize { @server_requests.delete(msg[:id]) }
      q&.push(msg)
    end

    # Send a server->client request and block (bounded) for the reply. The reply
    # arrives on the reader thread and is routed via route_server_response, so the
    # CALLING thread (the worker) must not be the reader. Returns the result, or
    # nil on timeout / error / a client that doesn't answer. ids are a distinct
    # string namespace so they can never collide with the client's own request ids.
    def server_request(method, params, timeout: 30)
      id = @sr_mutex.synchronize { @sr_seq += 1; "mruby-lsp-srv-#{@sr_seq}" }
      q  = Queue.new
      @sr_mutex.synchronize { @server_requests[id] = q }
      enqueue({ jsonrpc: "2.0", id: id, method: method, params: params })
      msg =
        begin
          require "timeout"
          Timeout.timeout(timeout) { q.pop }
        rescue Timeout::Error
          nil
        ensure
          @sr_mutex.synchronize { @server_requests.delete(id) }
        end
      msg && msg[:error].nil? ? msg[:result] : nil
    end

    # The sandbox decision for an LSP client (non-tty). Called once after
    # `initialized`. The interactive/TTY case is handled in the entry script
    # BEFORE the LSP loop; here we are always under a client, so we ask via a
    # native dialog (window/showMessageRequest). :confined and :unsupported never
    # reach here. NEVER run unconfined silently: no consent (or no dialog support)
    # -> abort. No env var, no flag — the answer comes from the kernel status plus
    # the user's button.
    CONTINUE_UNSANDBOXED = "Continue without sandbox"
    def enforce_sandbox_consent
      require_relative "sandbox_status"
      return unless SandboxStatus.unconfined?
      warning = "mruby-lsp could not enable its filesystem sandbox " \
                "(Landlock is unavailable on this kernel)."
      # Running unsandboxed requires the user's EXPLICIT consent. We get it only
      # through the answerable dialog (window/showMessageRequest), which the client
      # advertises as the window.showMessage capability — checked, never a tty
      # guess. If the client CAN'T show a dialog, or the user declines, or no
      # answer comes, there is no consent — and with no consent we FAIL CLOSED.
      consent =
        if @client_capabilities.to_h.dig(:window, :showMessage)
          res = server_request("window/showMessageRequest", {
            type: 2, # Warning
            message: "#{warning} Run without it?",
            actions: [{ title: CONTINUE_UNSANDBOXED }, { title: "Abort" }],
          })
          res && res[:title] == CONTINUE_UNSANDBOXED
        else
          false # cannot ask -> cannot consent
        end

      if consent
        log_message("running WITHOUT the sandbox, by explicit user consent", type: 2)
      else
        # No explicit consent (declined, no answer, or no dialog support): shut
        # down. ANNOUNCE it visibly (window/showMessage, not just the log) so the
        # client/user sees WHY the connection ends; terminate() flushes the queue
        # before the process exits.
        show_message("#{warning} mruby-lsp needs the sandbox, or your explicit " \
                     "consent to run without it; shutting down.", type: 1)
        terminate(1)
      end
    end

    # Raised when a handler outruns REQUEST_TIMEOUT_SECONDS.
    class RequestTimeout < StandardError; end

    # Per-request wall-clock budget. The risky work (live VM reflection, and
    # addr2line via IO.popen for C-method locations) is all GVL-RELEASING — pure
    # Ruby blocked on a subprocess pipe — so a watcher can actually interrupt it.
    # A handler that exceeds this is treated as wedged and abandoned. Generous
    # enough that a legitimately slow first-time addr2line batch on a big binary
    # still completes; short enough that a true wedge doesn't hang the editor.
    #
    # Configurable, highest precedence first:
    #   1. initializationOptions.requestTimeoutSeconds  (editor settings UI)
    #   2. MRUBY_LSP_REQUEST_TIMEOUT env var            (shell / raw clients)
    #   3. DEFAULT_REQUEST_TIMEOUT_SECONDS              (fallback)
    # A value of 0 or negative disables the cap entirely (handlers run unbounded
    # — opt-in, for users who would rather block than ever lose a slow result).
    DEFAULT_REQUEST_TIMEOUT_SECONDS = 15

    # Resolve the configured budget from initializationOptions, falling back to
    # the env var, then the default. Tolerant of junk (non-numeric -> default).
    def configure_request_timeout(init_options)
      raw =
        (init_options && (init_options[:requestTimeoutSeconds] ||
                          init_options["requestTimeoutSeconds"])) ||
        ENV["MRUBY_LSP_REQUEST_TIMEOUT"]
      @request_timeout_seconds =
        if raw.nil? || raw.to_s.strip.empty?
          DEFAULT_REQUEST_TIMEOUT_SECONDS
        else
          n = Float(raw, exception: false)
          n.nil? ? DEFAULT_REQUEST_TIMEOUT_SECONDS : n
        end
    end

    def request_timeout_seconds
      @request_timeout_seconds || DEFAULT_REQUEST_TIMEOUT_SECONDS
    end

    # Run a handler with a wall-clock cap. Handlers execute in the single worker
    # thread; we move the work to a child thread and join with a timeout so the
    # worker itself stays responsive. On miss we kill the child and raise — the
    # child's work is read-only reflection (no shared mutation to corrupt), and
    # killing a thread blocked in GVL-releasing IO.popen actually lands.
    #
    # Thread#value re-raises any real exception from the work, so genuine handler
    # errors still surface to dispatch's StandardError rescue unchanged.
    #
    # A non-positive budget means "no cap": run inline, no watcher thread.
    def with_timeout(seconds)
      return yield if seconds.nil? || seconds <= 0

      worker = Thread.new do
        Thread.current.report_on_exception = false
        yield
      end
      if worker.join(seconds)
        worker.value
      else
        worker.kill
        worker.join(1) # let the kill settle; bounded so a truly stuck child can't stall us
        raise RequestTimeout
      end
    end

    # Compact "uri:line:char" (or just method params) for log context.
    def request_context(msg)
      p = msg[:params] || {}
      uri = p.dig(:textDocument, :uri)
      pos = p[:position]
      if uri && pos
        "#{File.basename(uri.to_s)}:#{pos[:line]}:#{pos[:character]}"
      elsif uri
        File.basename(uri.to_s)
      else
        "no-position"
      end
    end

    # Map LSP method strings to Ruby handler method names, avoiding conflicts
    # with Ruby's own initialize. shutdown/exit are intentionally absent: the
    # reader thread handles them inline via handle_urgent so they never queue
    # behind a long-running handler.
    METHOD_MAP = {
      "initialize"              => :lsp_initialize,
      "initialized"             => :lsp_initialized,
      "textDocument/didOpen"    => :text_document_did_open,
      "textDocument/didChange"  => :text_document_did_change,
      "textDocument/didClose"   => :text_document_did_close,
      "textDocument/didSave"    => :text_document_did_save,
      "textDocument/completion" => :text_document_completion,
      "completionItem/resolve"  => :completion_item_resolve,
      "textDocument/hover"      => :text_document_hover,
      "mrubyLsp/evaluatableExpression" => :mruby_lsp_evaluatable_expression,
      "textDocument/definition" => :text_document_definition,
      "textDocument/documentSymbol" => :text_document_document_symbol,
      "textDocument/foldingRange" => :text_document_folding_range,
      "textDocument/selectionRange" => :text_document_selection_range,
      "textDocument/documentHighlight" => :text_document_document_highlight,
      "workspace/symbol" => :workspace_symbol,
      "textDocument/references" => :text_document_references,
      "textDocument/rename" => :text_document_rename,
      "textDocument/prepareRename" => :text_document_prepare_rename,
      "textDocument/signatureHelp" => :text_document_signature_help,
      "textDocument/documentLink" => :text_document_document_link,
      "textDocument/codeLens" => :text_document_code_lens,
      "textDocument/codeAction" => :text_document_code_action,
      "textDocument/inlayHint" => :text_document_inlay_hint,
      "textDocument/diagnostic" => :text_document_diagnostic,
      "textDocument/rangeFormatting" => :text_document_range_formatting,
      "textDocument/onTypeFormatting" => :text_document_on_type_formatting,
      "textDocument/semanticTokens/full" => :text_document_semantic_tokens_full,
      "textDocument/semanticTokens/range" => :text_document_semantic_tokens_range,
      "textDocument/prepareTypeHierarchy" => :text_document_prepare_type_hierarchy,
      "typeHierarchy/supertypes" => :type_hierarchy_supertypes,
      "typeHierarchy/subtypes" => :type_hierarchy_subtypes,
    }.freeze

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def lsp_initialize(msg)
      # Per-request timeout budget from initializationOptions (or env/default).
      configure_request_timeout(msg.dig(:params, :initializationOptions))
      # Remember the client's capabilities — the reliable per-client signal for
      # whether it can show an answerable dialog (window/showMessageRequest),
      # used by the sandbox-consent gate. NOT a tty guess.
      @client_capabilities = msg.dig(:params, :capabilities) || {}
      # Negotiate position encoding exactly like ruby-lsp: no offer -> utf-16;
      # utf-8 if offered; else utf-16 if offered; else utf-32. Drives all
      # column<->byte math via Locator and the semantic-token code-unit cache.
      client_encs = msg.dig(:params, :capabilities, :general, :positionEncodings) || []
      negotiated =
        if client_encs.empty? then "utf-16"
        elsif client_encs.include?("utf-8") then "utf-8"
        elsif client_encs.include?("utf-16") then "utf-16"
        else "utf-32"
        end
      require_relative "locator"
      Locator.encoding = negotiated
      {
        capabilities: {
          positionEncoding: negotiated,
          completionProvider:  { triggerCharacters: [".", ":", "@", "$"], resolveProvider: true },
          hoverProvider:       true,
          definitionProvider:  true,
          documentSymbolProvider: true,
          foldingRangeProvider: true,
          selectionRangeProvider: true,
          documentHighlightProvider: true,
          workspaceSymbolProvider: true,
          referencesProvider: true,
          renameProvider: { prepareProvider: true },
          signatureHelpProvider: { triggerCharacters: ["(", ","] },
          documentLinkProvider: { resolveProvider: false },
          codeLensProvider: { resolveProvider: false },
          codeActionProvider: { resolveProvider: true, codeActionKinds: ["quickfix", "refactor.extract", "refactor.rewrite"] },
          inlayHintProvider: {},
          diagnosticProvider: { interFileDependencies: false, workspaceDiagnostics: false },
          documentRangeFormattingProvider: true,
          documentOnTypeFormattingProvider: { firstTriggerCharacter: "{", moreTriggerCharacter: ["\n", "|", "d"] },
          semanticTokensProvider: {
            legend: MrubyLsp::SemanticTokens.legend,
            range: true,
            full: { delta: true }
          },
          typeHierarchyProvider: true,
          textDocumentSync: {
            openClose: true,
            change:    1,  # full-text sync (incremental deliberately deferred)
            save:      true
          }
        },
        serverInfo: { name: "mruby-lsp", version: MrubyLsp::VERSION }
      }
    end

    def lsp_initialized(msg)  = nil  # notification, no response

    # ── Documents ────────────────────────────────────────────────────────────

    def text_document_did_open(msg)
      td = msg[:params][:textDocument]
      @mutex.synchronize { @store.open(td[:uri], td[:text], td[:version]) }
      nil
    end

    def text_document_did_change(msg)
      td      = msg[:params][:textDocument]
      changes = msg[:params][:contentChanges]
      # Full-text sync for now (T2.2 handles incremental + UTF-16)
      text = changes.last[:text]
      @mutex.synchronize { @store.get(td[:uri])&.update(text, td[:version]) }
      nil
    end

    def text_document_did_close(msg)
      @mutex.synchronize { @store.close(msg[:params][:textDocument][:uri]) }
      nil
    end

    # Saved to disk. The concrete Server decides whether this triggers a
    # rebuild (standing consent only — see Server#text_document_did_save).
    def text_document_did_save(_msg)
      nil
    end
  end
end
