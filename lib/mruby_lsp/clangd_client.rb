# frozen_string_literal: true

require "open3"
require "thread"
require "timeout"
require "language_server/protocol"

module MrubyLsp
  # A thin LSP *client* that drives our own managed clangd subprocess, used for C
  # method return-type inference (Stage 3) and C hover/definition. It rides the
  # language_server-protocol gem's framing (Transport::Io) — same wire code as our
  # server — so there is no second hand-rolled header parser.
  #
  # BYO toolchain: clangd is found on PATH; if it is absent or fails to spawn, the
  # client is simply dead (`alive? == false`) and every request returns nil — the
  # C features switch off, nothing crashes. Same on EOF (clangd died mid-session).
  #
  # NOTE on what we ask clangd: every mruby C method has the SAME C signature
  # (`mrb_value f(mrb_state*, mrb_value)`), so the signature is useless for the
  # Ruby-level return type. That type lives in the function BODY — which
  # mrb_value-constructor the return expressions use. So the inference step (built
  # on top of this client) asks for `textDocument/ast` and inspects the return
  # subtree, NOT hover/signature. This file is only the transport+lifecycle.
  class ClangdClient
    REQUEST_TIMEOUT = 5.0  # a hung clangd must never block an editor request

    def self.start(compile_commands_dir:, query_driver: nil, clangd: "clangd")
      new(compile_commands_dir: compile_commands_dir, query_driver: query_driver, clangd: clangd)
    end

    def initialize(compile_commands_dir:, query_driver: nil, clangd: "clangd")
      args = ["--compile-commands-dir=#{compile_commands_dir}", "--background-index=false"]
      args << "--query-driver=#{query_driver}" if query_driver
      @stdin, @stdout, @stderr, @wait = Open3.popen3(clangd, *args)
      @writer  = LanguageServer::Protocol::Transport::Io::Writer.new(@stdin)
      @reader  = LanguageServer::Protocol::Transport::Io::Reader.new(@stdout)
      @pending = {}            # id => Queue (one reply)
      @mutex   = Mutex.new
      @seq     = 0
      @alive   = true
      @stderr_thread = Thread.new { @stderr.each_line { |_| } } # drain, don't deadlock
      @reader_thread = Thread.new { run_reader }
      initialize_handshake
    rescue Errno::ENOENT
      # clangd not on PATH / spawn failed -> dead client, features off.
      @alive = false
      cleanup
    end

    def alive? = @alive

    # Synchronous request -> result hash, or nil (timeout / dead / error reply).
    def request(method, params)
      return nil unless @alive
      id = next_id
      q  = Queue.new
      @mutex.synchronize { @pending[id] = q }
      @writer.write(id: id, method: method, params: params)
      begin
        msg = Timeout.timeout(REQUEST_TIMEOUT) { q.pop }
      rescue Timeout::Error
        return nil
      ensure
        @mutex.synchronize { @pending.delete(id) }
      end
      msg && msg[:error].nil? ? msg[:result] : nil
    end

    def notify(method, params)
      return unless @alive
      @writer.write(method: method, params: params)
    rescue IOError
      mark_dead
    end

    # didOpen a C file so clangd parses it; text is the file contents.
    def did_open(uri, text, language_id: "c")
      notify("textDocument/didOpen",
             textDocument: { uri: uri, languageId: language_id, version: 1, text: text })
    end

    def did_close(uri)
      notify("textDocument/didClose", textDocument: { uri: uri })
    end

    # Full-content sync: replace the open buffer for uri. Used to feed clangd a
    # synthetic completion context (see CTypeResolver#doc). Version just has to
    # increase; a monotonic counter satisfies clangd.
    def did_change(uri, text)
      @change_seq = (@change_seq || 1) + 1
      notify("textDocument/didChange",
             textDocument: { uri: uri, version: @change_seq },
             contentChanges: [{ text: text }])
    end

    def stop
      return unless @alive
      request("shutdown", nil)
      notify("exit", nil)
    ensure
      mark_dead
    end

    private

    def next_id
      @mutex.synchronize { @seq += 1 }
    end

    def initialize_handshake
      res = request("initialize", {
        processId: Process.pid,
        rootUri: nil,
        capabilities: {
          textDocument: { hover: { contentFormat: ["plaintext"] } },
          general: { positionEncodings: ["utf-16"] },
        },
      })
      raise "clangd initialize failed" unless res
      notify("initialized", {})
    end

    # Dedicated reader thread: route replies to their waiting Queue, answer
    # server->client requests (so clangd never blocks on us), drop notifications.
    def run_reader
      @reader.read do |msg|
        if msg[:id] && (msg.key?(:result) || msg.key?(:error))
          q = @mutex.synchronize { @pending[msg[:id]] }
          q&.push(msg)
        elsif msg[:id] && msg[:method]
          answer_server_request(msg)
        end
        # else: a notification (window/logMessage, $/progress, diagnostics) -> ignore
      end
    rescue IOError
      # io closed / parse error
    ensure
      # EOF: clangd is gone. Wake every waiter with a nil so no request hangs.
      mark_dead
      @mutex.synchronize do
        @pending.each_value { |q| q.push(nil) }
        @pending.clear
      end
    end

    # Minimal but correct replies so clangd's startup requests resolve.
    def answer_server_request(msg)
      result =
        case msg[:method]
        when "workspace/configuration"
          Array(msg.dig(:params, :items)).map { nil } # one (null) setting per item
        else
          nil # registerCapability, workDoneProgress/create, ... -> null is fine
        end
      @writer.write(id: msg[:id], result: result)
    rescue IOError
      mark_dead
    end

    def mark_dead
      @alive = false
    end

    def cleanup
      [@stdin, @stdout, @stderr].each { |io| io&.close }
    end
  end
end
