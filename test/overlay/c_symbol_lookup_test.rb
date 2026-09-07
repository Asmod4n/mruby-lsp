$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "tmpdir"
require "mruby_lsp/c_type_resolver"

# A C++ source names a function one way to addr2line and another way to clangd.
# These cases pin the join between the two. The clangd client is a stub that
# answers documentSymbol from a table, so the test needs no clangd and no VM.

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

# Two functions, 0-based lines 10..14 and 20..24.
SYMBOLS = [
  { name: "watcher_events", kind: 12,
    location: { range: { start: { line: 10, character: 0 }, end: { line: 14, character: 1 } } } },
  { name: "watcher_source", kind: 12,
    location: { range: { start: { line: 20, character: 0 }, end: { line: 24, character: 1 } } } },
  { name: "a_variable", kind: 13,
    location: { range: { start: { line: 30, character: 0 }, end: { line: 30, character: 9 } } } },
].freeze

class StubClient
  def alive? = true
  def did_open(_uri, _text); end
  def did_change(_uri, _text); end
  def request(method, **_params)
    method == "textDocument/documentSymbol" ? SYMBOLS : nil
  end
end

R = MrubyLsp::CTypeResolver.new(StubClient.new)
# ranges_for hands clangd the file's text, so the path must exist. Its content
# is never read back -- the stub answers documentSymbol from the table above.
DIR = Dir.mktmpdir
FILE = File.join(DIR, "watcher.cpp")
File.write(FILE, "// 35 lines of C++\n" * 35)
at_exit { require "fileutils"; FileUtils.remove_entry(DIR) }
def sym(func, line = nil) = R.send(:symbol_for, FILE, func, line)

# C: addr2line and clangd agree, and the name alone answers.
check.call("plain C name matches by name", sym("watcher_events")&.dig(:name), "watcher_events")
check.call("plain C name, line ignored", sym("watcher_events", 12)&.dig(:name), "watcher_events")

# C++: addr2line reports the demangled, qualified definition. The name misses,
# and the definition line (1-based 11 == 0-based 10) places it.
CXX = "webmachine::(anonymous namespace)::watcher_events(mrb_state*, mrb_value)"
check.call("C++ qualified name, no line -> nothing", sym(CXX), nil)
check.call("C++ qualified name, definition line", sym(CXX, 11)&.dig(:name), "watcher_events")
check.call("C++ qualified name, line inside the body", sym(CXX, 15)&.dig(:name), "watcher_events")
check.call("C++ qualified name, the other function", sym(CXX, 21)&.dig(:name), "watcher_source")

# A line no function covers must resolve to nothing, never to a neighbour.
check.call("line between functions -> nothing", sym(CXX, 18), nil)
check.call("line 0 -> nothing", sym(CXX, 0), nil)
check.call("unknown name, no line -> nothing", sym("nope"), nil)

# Only functions (SymbolKind 12) are candidates; a variable never answers.
check.call("a variable is not a function", sym(CXX, 31), nil)

puts(fail_count.zero? ? "\nALL PASS" : "\n#{fail_count} FAILED")
exit(fail_count.zero? ? 0 : 1)
