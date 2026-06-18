# frozen_string_literal: true

require "mkmf"

# CRuby face. Always builds the neutral core (src/vb.c) and the CRuby leg
# (cruby/vb_cruby.c) -- both need only ruby.h. The mruby leg (src/vb_mruby.c) is
# added only when a libmruby is discoverable, since a CRuby host that wants
# mrb_value <-> vb_value must link one.

require "fileutils"

this   = __dir__
root   = File.expand_path("../..", this)

# Paths can contain spaces (e.g. installed under "Code - OSS/.../globalStorage").
# mkmf embeds include/VPATH paths verbatim into the Makefile where they are
# shell/make-evaluated, and neither -I nor VPATH survives a space cleanly
# (unquoted splits the path; quoted breaks make's VPATH list). Rather than fight
# that, stage every source + header NEXT TO extconf (relative paths, no spaces in
# the relative part) and compile them locally. Self-contained, space-proof.
{
  File.join(root, "include") => %w[vb.h vb_cruby.h vb_mruby.h],
  File.join(root, "src")     => %w[vb.c vb_names.c vb_mruby.c],
  File.join(root, "cruby")   => %w[vb_cruby.c],
}.each do |dir, files|
  files.each do |f|
    src = File.join(dir, f)
    FileUtils.cp(src, File.join(this, f)) if File.file?(src)
  end
end

$srcs = %w[vb_ext.c vb.c vb_names.c vb_cruby.c]

mruby_config = ENV["MRUBY_CONFIG"] || (find_executable("mruby-config") && "mruby-config")
if mruby_config
  cflags  = `#{mruby_config} --cflags`.strip
  ldflags = `#{mruby_config} --ldflags`.strip
  libs    = `#{mruby_config} --libs`.strip
  unless cflags.empty?
    $CFLAGS  << " " << cflags
    $LDFLAGS << " " << ldflags
    $libs    << " " << libs
    $srcs    << "vb_mruby.c"            # from src/ via VPATH
    $defs    << "-DVALUE_BRIDGE_HAVE_MRUBY"
    message "value_bridge: mruby leg ENABLED via #{mruby_config}\n"
  end
else
  message "value_bridge: mruby leg disabled (no mruby-config); CRuby leg only\n"
end

create_makefile("value_bridge/value_bridge_ext")
