$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "mruby_lsp/index"

IDX = MrubyLsp::Index.new
IDX.set_ivar_schema("Foo", { "@s" => ["Socket"], "@u" => ["Integer", "String"] })

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

check.call("single concrete type -> name",      IDX.ivar_type("Foo", "@s"), "Socket")
check.call("union (>1) -> nil (never guess)",    IDX.ivar_type("Foo", "@u"), nil)
check.call("undeclared ivar -> nil",             IDX.ivar_type("Foo", "@nope"), nil)
check.call("undeclared class -> nil",            IDX.ivar_type("Bar", "@s"), nil)
check.call("symbol ivar key tolerated",          IDX.ivar_type("Foo", :@s), "Socket")

puts(fail_count.zero? ? "\nALL PASS" : "\n#{fail_count} FAILED")
exit(fail_count.zero? ? 0 : 1)
