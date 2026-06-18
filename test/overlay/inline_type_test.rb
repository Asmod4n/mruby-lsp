$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "mruby_lsp/inline_type"
IT = MrubyLsp::InlineType

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

sig  = ->(p) { (m = IT.parse(p))   && m.to_s }                 # payload -> "(...) -> T" | nil
xsig = ->(l) { (m = IT.extract(l)) && m.to_s }                 # full line -> ... | nil
rcn  = ->(p) { (m = IT.parse(p))   && IT.return_class_name(m) } # -> return class name | nil

# --- rbs parses the full grammar; we built none of it ---------------------
check.("basic",         sig.("(Integer, String) -> Array"),            "(Integer, String) -> Array")
check.("optional arg",  sig.("(Integer, ?String) -> Integer"),         "(Integer, ?String) -> Integer")
check.("splat",         sig.("(*Integer) -> void"),                    "(*Integer) -> void")
check.("keyword",       sig.("(name: String, ?age: Integer?) -> nil"), "(name: String, ?age: Integer?) -> nil")
check.("generic",       sig.("() -> Array[String]"),                   "() -> Array[String]")
check.("union",         sig.("() -> (Integer | nil)"),                 "() -> (Integer | nil)")
check.("block",         sig.("() { (Integer) -> void } -> bool"),      "() { (Integer) -> void } -> bool")
check.("top-level",     sig.("() -> ::Foo::Bar"),                      "() -> ::Foo::Bar")

# --- both markers, dedicated-line rule ------------------------------------
check.("rb marker",     xsig.("  #: (Integer) -> String"),   "(Integer) -> String")
check.("c marker",      xsig.("  //: (Integer) -> String"),  "(Integer) -> String")
check.("c tight",       xsig.("//:(String)->Array"),         "(String) -> Array")
check.("plain comment", IT.extract("# just a comment"),      nil)
check.("no marker",     IT.extract("static mrb_value"),      nil)
check.("inline trail",  IT.extract("size_t f(int x); // one"), nil)

# --- return class name for the resolver -----------------------------------
check.("rcn instance",  rcn.("(Integer) -> ::Foo::Bar"), "::Foo::Bar")
check.("rcn generic",   rcn.("() -> Array[String]"),     "Array")
check.("rcn nilclass",  rcn.("() -> NilClass"),          "NilClass")
check.("rcn void",      rcn.("() -> void"),              nil)
check.("rcn untyped",   rcn.("() -> untyped"),           nil)
check.("rcn union",     rcn.("() -> (Integer | nil)"),   nil)
check.("rcn singleton", rcn.("() -> singleton(Foo)"),    nil)

# --- malformed -> nil (rbs rejects; external text, not our bug) -----------
check.("garbage",       IT.parse("hello world"), nil)
check.("unbalanced",    IT.parse("(Integer"),    nil)
check.("empty payload", IT.parse(""),            nil)
check.("empty marker",  IT.extract("#:"),        nil)

puts
puts "inline_type failing=#{fail_count}/27"
exit(fail_count.zero? ? 0 : 1)
