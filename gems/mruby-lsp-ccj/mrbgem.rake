# frozen_string_literal: true

# Emits a clangd-shape compile_commands.json for the injected -mruby-lsp build,
# the presym way: no Compiler#run wrap. A vendored, source-less gem injects one
# build task (mrbgem.rake is `load`ed at top level by load_gems.rb, so Rake DSL
# and MRuby::Build.current are available here) and adds it as a product dep.
#
# Per-object reconstruction, not capture: each entry's flags come from the SAME
# compiler the real rule uses -- define_rules calls `run` with no extra
# defines/includes/flags, so all_flags([],[],[]) on the owning compiler matches
# byte-for-byte (incl. each gem's -DMRBGEM_* via that gem's compiler).
#
# Incremental + self-pruning, both load-bearing and both verified:
#   * the DB depends on libmruby_static -> it reruns whenever the lib relinks
#     (i.e. whenever any source changed), and the recipe rebuilds the WHOLE set,
#     so a partial rebuild never truncates it.
#   * the set is build.libmruby_objs, recomputed from the current gem set each
#     build -- a removed gem's objects simply aren't in it (stale .o on disk is
#     ignored). mrbc's bootstrap objects live in a separate sub-build, so they
#     never appear here; no /mrbc/ filter needed.
#
# CLocator consumes <build.build_dir>/compile_commands.json: addr2line -> source
# file, this -> exact flags for that file. Dumb path lookup, no mrb_define*.

require "json"
require "shellwords"

MRuby::Gem::Specification.new("mruby-lsp-ccj") do |spec|
  spec.license = "MIT"
  spec.author  = "mruby-lsp"
  spec.summary = "emits compile_commands.json for the reflected build"
end

build = MRuby::Build.current
db    = "#{build.build_dir}/compile_commands.json"

emit = lambda do
  entries = build.libmruby_objs.flatten.uniq.filter_map do |obj|
    task = Rake.application.lookup(obj)
    src  = task && task.prerequisites.first
    next nil unless src && File.exist?(src)

    gem   = build.gems.find { |g| obj.start_with?("#{g.build_dir}/") }
    pool  = (gem ? gem.compilers : build.compilers)
    ext   = File.extname(src)
    comp  = pool.find { |c| c.source_exts.any? { |e| e == ext || e == ext.sub(/\A\./, "") } } || pool.first
    next nil unless comp

    flags = comp.all_flags([], [], [])
    {
      "directory" => MRUBY_ROOT,
      "file"      => src,
      "arguments" => [build.filename(comp.command), *Shellwords.split(flags), "-c", src, "-o", obj],
      "output"    => obj,
    }
  end
  File.write(db, JSON.pretty_generate(entries))
end

# Name reference is fine: libmruby_static's file task is defined later in
# libmruby.rake. Adding to products makes a normal build emit the DB.
file db => build.libmruby_static do
  emit.call
end
build.products << db
