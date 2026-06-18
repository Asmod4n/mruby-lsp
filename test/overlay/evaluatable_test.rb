$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
%w[locator evaluatable].each { |f| require "mruby_lsp/#{f}" }

# Exhaustive debug-hover check: take a realistic IO server, then walk the cursor
# over EVERY character of EVERY line and assert the evaluatable expression is
# never a broken fragment. The point of the prism-backed provider is that no
# position can ever produce something mrdb would choke on (e.g. `"hello`).

fails = 0
check = lambda do |label, ok, detail = nil|
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        #{detail}" if !ok && detail
end

# Non-interpolating heredoc: the `#{…}` here is mruby SOURCE under test, not Ruby
# string interpolation in this test file.
SERVER_SRC = <<~'RB'
  class EchoServer
    def initialize(host, port)
      @host = host
      @port = port
      @clients = []
    end

    def start
      server = TCPServer.new(@host, @port)
      loop do
        conn = server.accept
        handle(conn)
      end
    end

    def handle(conn)
      line = conn.gets
      response = "echo: #{line}"
      conn.write(response)
      conn.close
    end
  end

  PORT = 8080
  server = EchoServer.new("127.0.0.1", PORT)
  server.start
RB

# And an IO CLIENT that connects to that server and walks its own variables.
CLIENT_SRC = <<~'RB'
  HOST = "127.0.0.1"
  PORT = 8080

  def send_message(socket, text)
    socket.write("#{text}\n")
    reply = socket.gets
    puts "server said: #{reply.chomp}"
    reply
  end

  sock = TCPSocket.new(HOST, PORT)
  messages = ["ping", "hello world", "bye"]
  messages.each do |msg|
    answer = send_message(sock, msg)
    @last = answer
  end
  sock.close
RB

SRC = SERVER_SRC # primary subject for the named-case assertions below
doc = Struct.new(:ast, :text).new(Prism.parse(SRC), SRC)
lines = SRC.lines

# Map every (line, character) over a source. For each non-nil result assert:
#   (1) expression == the slice of the returned range (range/text agree);
#   (2) the expression PARSES with no Prism errors (it's complete — never a
#       dangling quote like `"hello`);
#   (3) it is not an assignment (no `=` at statement level) — we hand back the
#       target NAME, never `a = 1`.
walk_all = lambda do |label, src|
  d = Struct.new(:ast, :text).new(Prism.parse(src), src)
  ls = src.lines
  slice_at = lambda do |range|
    s = range[:start]; e = range[:end]
    if s[:line] == e[:line]
      ls[s[:line]][s[:character]...e[:character]]
    else
      out = ls[s[:line]][s[:character]..]
      (s[:line] + 1...e[:line]).each { |i| out += ls[i] }
      out + ls[e[:line]][0...e[:character]]
    end
  end

  broken = []; mismatched = []; assignments = []; total = 0; nonnil = 0
  ls.each_with_index do |line, li|
    (0..line.length).each do |ch|
      total += 1
      res = MrubyLsp::Evaluatable.response(d, { line: li, character: ch })
      next unless res
      nonnil += 1
      got = slice_at.call(res[:range])
      mismatched << [li, ch, got, res[:expression]] unless got == res[:expression]
      parsed = Prism.parse(res[:expression])
      broken << [li, ch, res[:expression]] unless parsed.errors.empty?
      stmt = parsed.value.statements.body.first
      if stmt.is_a?(Prism::LocalVariableWriteNode) || stmt.is_a?(Prism::InstanceVariableWriteNode) ||
         stmt.is_a?(Prism::ClassVariableWriteNode) || stmt.is_a?(Prism::GlobalVariableWriteNode) ||
         stmt.is_a?(Prism::ConstantWriteNode) || stmt.is_a?(Prism::MultiWriteNode)
        assignments << [li, ch, res[:expression]]
      end
    end
  end

  check.("[#{label}] every position parses (no broken fragments)", broken.empty?,
         broken.first(5).map { |l, c, e| "L#{l}:#{c} -> #{e.inspect}" }.join("; "))
  check.("[#{label}] range and expression always agree", mismatched.empty?,
         mismatched.first(5).map { |l, c, g, e| "L#{l}:#{c} #{g.inspect} != #{e.inspect}" }.join("; "))
  check.("[#{label}] never returns an assignment", assignments.empty?,
         assignments.first(5).map { |l, c, e| "L#{l}:#{c} -> #{e.inspect}" }.join("; "))
  puts "        (#{nonnil}/#{total} positions resolved to an expression)"
end

walk_all.call("server", SERVER_SRC)
walk_all.call("client", CLIENT_SRC)

# Targeted assertions: the cases the user walked over by hand.
at = lambda do |needle, into, finder = SRC|
  li = lines.index { |l| l.include?(needle) }
  col = lines[li].index(needle) + into
  MrubyLsp::Evaluatable.response(doc, { line: li, character: col })
end

# `response = "echo: #{line}"` — hovering ANYWHERE in the string literal (the
# opening quote, the `echo:` text, the interpolation braces) gives the WHOLE
# literal; hovering the interpolated `line` gives just `line`.
str_line = lines.index { |l| l.include?('"echo:') }
str_col  = lines[str_line].index('"echo:')
whole = '"echo: #{line}"'
%w[quote text hash brace].each_with_index do |_, _i|; end
[
  ["opening quote",        str_col,          whole],
  ["literal text 'echo'",  str_col + 2,      whole],
  ["the '#' of #{}",       str_col + 8,      whole],
].each do |label, col, want|
  r = MrubyLsp::Evaluatable.response(doc, { line: str_line, character: col })
  check.("string hover (#{label}) -> whole literal", r && r[:expression] == want,
         r ? r[:expression].inspect : "nil")
end
# the interpolated value resolves to just `line`
ln_col = lines[str_line].index("line", str_col)
r = MrubyLsp::Evaluatable.response(doc, { line: str_line, character: ln_col + 1 })
check.("interpolated value -> 'line'", r && r[:expression] == "line", r ? r[:expression].inspect : "nil")

# `puts`/side-effecting call with args is NOT evaluated: `conn.write(response)`
wl = lines.index { |l| l.include?("conn.write(") }
wc = lines[wl].index("write") + 1
r = MrubyLsp::Evaluatable.response(doc, { line: wl, character: wc })
check.("call WITH args (conn.write) -> nil", r.nil?, r ? r[:expression].inspect : "nil")

# an ivar read resolves to the ivar
hl = lines.index { |l| l.include?("@host = host") }
r = MrubyLsp::Evaluatable.response(doc, { line: hl, character: lines[hl].index("@host") + 1 })
check.("ivar read -> '@host'", r && r[:expression] == "@host", r ? r[:expression].inspect : "nil")

# the assignment target `server` resolves to the name, not `server = …`
sl = lines.index { |l| l.include?("server = EchoServer.new") }
r = MrubyLsp::Evaluatable.response(doc, { line: sl, character: lines[sl].index("server") + 1 })
check.("assignment target -> name only ('server')", r && r[:expression] == "server",
       r ? r[:expression].inspect : "nil")

# a constant read resolves to the constant
r = MrubyLsp::Evaluatable.response(doc, { line: sl, character: lines[sl].index("EchoServer") + 1 })
check.("constant read -> 'EchoServer'", r && r[:expression] == "EchoServer", r ? r[:expression].inspect : "nil")

# a standalone (non-interpolated) string literal -> the whole quoted string,
# from any interior character. `EchoServer.new("127.0.0.1", PORT)`
al = lines.index { |l| l.include?('"127.0.0.1"') }
r = MrubyLsp::Evaluatable.response(doc, { line: al, character: lines[al].index("127") })
check.("standalone string arg -> '\"127.0.0.1\"'", r && r[:expression] == '"127.0.0.1"', r ? r[:expression].inspect : "nil")

# ── walk the CLIENT's variables, the way you would while it's stopped ────────
cdoc = Struct.new(:ast, :text).new(Prism.parse(CLIENT_SRC), CLIENT_SRC)
clines = CLIENT_SRC.lines
cat = lambda do |needle, into = 1|
  li = clines.index { |l| l.include?(needle) }
  col = clines[li].index(needle) + into
  MrubyLsp::Evaluatable.response(cdoc, { line: li, character: col })
end
cstr = lambda { |needle, into = 1| r = cat.call(needle, into); r && r[:expression] }

check.("[client] local 'sock' read", cstr.call("sock = TCPSocket") == "sock")
check.("[client] block param 'msg'", cstr.call(", msg)", 2) == "msg")
check.("[client] constant 'HOST'", cstr.call("HOST =") == "HOST")
check.("[client] ivar-write target -> '@last'", cstr.call("@last = answer") == "@last")
check.("[client] interpolated reply.chomp method -> 'reply.chomp'",
       cstr.call(".chomp", 2) == "reply.chomp")
check.("[client] call WITH args (TCPSocket.new) -> nil on the method name",
       cat.call("TCPSocket.new", "TCPSocket.".length).nil?)

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
