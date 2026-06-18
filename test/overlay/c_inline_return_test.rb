$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "tmpdir"
require "mruby_lsp/c_type_resolver"

R = MrubyLsp::CTypeResolver.new(nil) # client nil: we drive the private annotation reader directly

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def ann(src, line)
  Dir.mktmpdir do |d|
    f = File.join(d, "t.c")
    File.write(f, src)
    R.send(:annotation_return, f, { start: { line: line } })
  end
end

SPLIT = <<~C
  //: (Integer) -> Array
  static mrb_value
  my_func(mrb_state *mrb, mrb_value self)
  {
    return mrb_ary_new(mrb);
  }
C

# clangd's symbol range may start at the func-name line (line 2, 0-based) ...
check.call("//: read past the storage line (range at func name)", ann(SPLIT, 2), "Array")
# ... or at the return-type/storage line (line 1)
check.call("//: directly above (range at storage line)", ann(SPLIT, 1), "Array")

ONELINE = <<~C
  //: () -> ::Foo
  mrb_value oneliner(mrb_state *mrb, mrb_value self) { return self; }
C
check.call("//: -> ::Foo one-line def", ann(ONELINE, 1), "::Foo")

NOANN = <<~C
  static mrb_value
  plain(mrb_state *mrb, mrb_value self)
  {
    return self;
  }
C
check.call("no annotation -> nil", ann(NOANN, 1), nil)

# A previous decl ending in `}` directly above must NOT leak its caller's annotation.
PREV = <<~C
  //: () -> Integer
  static mrb_value earlier(mrb_state *mrb, mrb_value self) { return self; }
  static mrb_value later(mrb_state *mrb, mrb_value self)
  {
    return self;
  }
C
# range at `later` (line 2): line above ends in `}` -> stop, no annotation leaks.
check.call("no leak from neighbour ending in }", ann(PREV, 2), nil)

# void return -> no concrete class
VOID = <<~C
  //: () -> void
  static mrb_value v(mrb_state *mrb, mrb_value self) { return self; }
C
check.call("//: void -> nil", ann(VOID, 1), nil)

puts(fail_count.zero? ? "\nALL PASS" : "\n#{fail_count} FAILED")
exit(fail_count.zero? ? 0 : 1)
