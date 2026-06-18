$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "mruby_lsp/index"
include MrubyLsp
E = MrubyLsp::Index::Entry

def entry(name, owner, kind, **opts)
  E.new(name: name, owner: owner, kind: kind, uri: "file:///b.rb", line: 1,
        params: opts[:params], native: false, singleton: false, doc: nil,
        mixins: opts[:mixins] || [], superclass: opts[:superclass])
end

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

# --- VM truth (compiled) ---
def fresh
  idx = MrubyLsp::Index.new
  idx.set_ancestors("String", %w[String Comparable Object Kernel BasicObject])
  idx.set_ancestors("Dog",    %w[Dog Animal Object Kernel BasicObject])
  idx.set_ancestors("Cat",    %w[Cat Object Kernel BasicObject])
  idx.set_ancestors("Animal", %w[Animal Object Kernel BasicObject])
  idx.set_ancestors("Object", %w[Object Kernel BasicObject])
  idx.set_ancestors("Kernel", %w[Kernel])
  idx.set_ancestors("BasicObject", %w[BasicObject])
  idx.set_ancestors("Comparable", %w[Comparable])
  idx
end

# 1. include on a VM class -> module spliced right after self
idx = fresh
idx.set_buffer("file:///b.rb", [
  entry("Greet", "Greet", :module),
  entry("Greet#hello", "Greet", :method, params: "()"),
  entry("String", "String", :class, mixins: [[:include, "Greet"]]),
], 0)
check.("include reopening String", idx.ancestors("String"),
       %w[String Greet Comparable Object Kernel BasicObject])
check.("  -> method visible via merged chain",
       idx.visible_methods("String").map(&:name).include?("Greet#hello"), true)

# 2. prepend on a VM class -> module spliced before self
idx = fresh
idx.set_buffer("file:///b.rb", [
  entry("Logged", "Logged", :module),
  entry("String", "String", :class, mixins: [[:prepend, "Logged"]]),
], 0)
check.("prepend reopening String", idx.ancestors("String"),
       %w[Logged String Comparable Object Kernel BasicObject])

# 3. prepend + include together
idx = fresh
idx.set_buffer("file:///b.rb", [
  entry("Logged", "Logged", :module),
  entry("Greet", "Greet", :module),
  entry("String", "String", :class, mixins: [[:prepend, "Logged"], [:include, "Greet"]]),
], 0)
check.("prepend+include reopening String", idx.ancestors("String"),
       %w[Logged String Greet Comparable Object Kernel BasicObject])

# 4. superclass replacement: buffer Dog < Cat cleanly replaces VM Dog < Animal
#    (vm_class? isolates Animal as the spine to drop; Cat's ancestry takes its place)
idx = fresh
idx.set_buffer("file:///b.rb", [
  entry("Dog", "Dog", :class, superclass: "Cat"),
], 0)
check.("superclass replacement drops old parent, keeps new",
       idx.ancestors("Dog"), %w[Dog Cat Object Kernel BasicObject])

# 5. dedup: including a module already compiled in is a no-op
idx = fresh
idx.set_buffer("file:///b.rb", [
  entry("String", "String", :class, mixins: [[:include, "Comparable"]]),
], 0)
check.("re-including a compiled module = no-op (no double)",
       idx.ancestors("String"), %w[String Comparable Object Kernel BasicObject])

# 6. regression: VM-only class untouched
idx = fresh
check.("VM-only class unchanged", idx.ancestors("Dog"),
       %w[Dog Animal Object Kernel BasicObject])

# 7. regression: buffer-only class still uses buffer MRO
idx = fresh
idx.set_buffer("file:///b.rb", [
  entry("Walk", "Walk", :module),
  entry("Robot", "Robot", :class, mixins: [[:include, "Walk"]]),
], 0)
check.("buffer-only class MRO", idx.ancestors("Robot"),
       %w[Robot Walk Object Kernel BasicObject])

puts "\n#{fail_count.zero? ? 'ALL PASS' : "#{fail_count} FAILED"}"
exit(fail_count.zero? ? 0 : 1)
