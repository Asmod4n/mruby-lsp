$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "mruby_lsp/test_harvester"
H = MrubyLsp::TestHarvester

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

h = ->(src) { H.harvest(src) }

# ── direct-type asserts name the type ────────────────────────────────────────
check.("kind_of -> direct class",
  h.(%(assert_kind_of(Integer, "abc".size))), { "String#size" => "Integer" })
check.("assert_float -> Float",
  h.(%(assert_float(1.0, 1.to_f))), { "Integer#to_f" => "Float" })
check.("assert_nil -> nil",
  h.(%(assert_nil("x".foo))), { "String#foo" => "nil" })
check.("assert_true/false -> bool (merge)",
  h.([%(assert_true("".empty?)), %(assert_false("x".empty?))]),
  { "String#empty?" => "bool" })

# ── assert_same is identity: act's type is the (typed) exp's ──────────────────
check.("assert_same literal exp -> String",
  h.(%(assert_same("", "x".clear))), { "String#clear" => "String" })
check.("assert_same traced exp -> class",
  h.(%(buf = "x"\nassert_same(buf, buf.itself))), { "String#itself" => "String" })

# ── equal-literal: trusted only when consistent; varying = leak, dropped ──────
check.("equal-literal consistent kept",
  h.([%(assert_equal(3, "abc".size)), %(assert_equal(5, "hello".size))]),
  { "String#size" => "Integer" })
check.("equal-literal varying -> dropped (leak)",
  h.([%(assert_equal(1, x.m)), %(assert_equal("a", x.m))]), {})
check.("direct + agreeing equal -> single",
  h.([%(assert_kind_of(Integer, "a".m)), %(assert_equal(5, "a".m))]),
  { "String#m" => "Integer" })

# ── content accessors dropped on BOTH tiers ──────────────────────────────────
check.("equal on accessor dropped",
  h.(%(assert_equal(1, [1, 2].at(0)))), {})
check.("kind_of on accessor dropped",
  h.(%(assert_kind_of(Integer, [1].first))), {})

# ── nil unions into a nilable type ───────────────────────────────────────────
check.("direct class + nil -> String?",
  h.([%(assert_kind_of(String, "x".g)), %(assert_nil("y".g))]),
  { "String#g" => "String?" })
check.("two classes -> union, sorted",
  h.([%(assert_kind_of(Integer, "a".q)), %(assert_kind_of(Float, "a".q))]),
  { "String#q" => "(Float | Integer)" })

# ── receiver attribution: Klass.new, local assignment, block param ───────────
check.("receiver via Klass.new",
  h.(%(assert_kind_of(Integer, Foo.new.bar))), { "Foo#bar" => "Integer" })
check.("receiver via local assignment",
  h.(%(x = Foo.new\nassert_kind_of(String, x.baz))), { "Foo#baz" => "String" })
check.("receiver via Klass.open block param",
  h.(%(File.open("p") { |io| assert_kind_of(String, io.slurp) })),
  { "File#slurp" => "String" })

# ── the running example, assembled from the real assertion shapes ────────────
io = <<~RB
  File.open("p") do |io|
    assert_equal "",      io.read(0)
    assert_equal "mruby", io.read(5)
    assert_nil            io.read(1)
  end
RB
check.("IO read pattern -> String? (read is not an accessor)",
  h.(io), { "File#read" => "String?" })

puts
puts "test_harvester failing=#{fail_count}/17"
exit(fail_count.zero? ? 0 : 1)
