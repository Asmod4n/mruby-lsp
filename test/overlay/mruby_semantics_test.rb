# frozen_string_literal: true

# mruby DYNAMIC-SEMANTICS conformance.
#
# The buffer overlay (buffer_harvester.rb + index.rb) models method-table
# mutations — undef/remove_method/alias/attr_*/define_method/module_function/
# visibility — using mruby's OBSERVED semantics, not CRuby's. Those semantics
# were established by running mruby, because mruby is a gem-composed subset and
# diverges from CRuby in real ways. This test pins them: it runs the project's
# mruby and asserts each behavior, so a gembox/version change that shifts the
# rules is caught here instead of silently making the overlay wrong.
#
# Point it at a build with: MRUBY=/path/to/bin/mruby ruby mruby_semantics_test.rb
# (defaults to the in-sandbox host build).

require "open3"
require "tempfile"

MRUBY = ENV.fetch("MRUBY", "/tmp/mruby/build/host/bin/mruby")

abort "mruby not found at #{MRUBY} (set MRUBY=...)" unless File.executable?(MRUBY)

# One mruby program that exercises every rule the overlay depends on and prints
# KEY=VALUE lines we assert against. Running it in-VM is the authority.
SCRIPT = <<~'MRB'
  def line(k, v) = puts("#{k}=#{v}")

  # undef_method: tombstone, blocks inherited
  class P1; def g; "p"; end; end
  class C1 < P1; undef_method :g; end
  line("undef_blocks_inherited", (begin; C1.new.g; "no"; rescue NoMethodError; "yes"; end))

  # remove_method: errors on a non-own (inherited) method
  class P2; def g; "p"; end; end
  class C2 < P2; end
  line("remove_inherited_raises", (begin; C2.class_eval { remove_method :g }; "no"; rescue NameError; "yes"; end))

  # remove_method: own copy only -> parent reappears
  class P3; def g; "p"; end; end
  class C3 < P3; def g; "c"; end; remove_method :g; end
  line("remove_own_reveals_parent", C3.new.g)

  # alias: snapshot of body at alias-time
  class A1; def v; "first"; end; alias snap v; def v; "second"; end; end
  line("alias_snapshots", "#{A1.new.snap}/#{A1.new.v}")

  # attr_* generated names
  class At; attr_reader :r; attr_writer :w; attr_accessor :a; end
  line("attr_names", %i[r r= w w= a a=].map { |m| At.instance_methods.include?(m) ? 1 : 0 }.join)

  # visibility: instance_methods excludes private; private_instance_methods has it
  class Vis; def pub; end; private; def priv; end; end
  line("private_excluded_from_instance_methods", Vis.instance_methods.include?(:priv) ? "no" : "yes")
  line("private_in_private_instance_methods", Vis.private_instance_methods.include?(:priv) ? "yes" : "no")

  # define_method ignores surrounding private in mruby (method is PUBLIC)
  class DM; private; define_method(:dm) { }; end
  line("define_method_public_despite_private", DM.instance_methods.include?(:dm) ? "yes" : "no")

  # module_function: explicit arg adds public singleton; instance stays public
  module MF; def helper; "h"; end; module_function :helper; end
  line("module_function_singleton", (begin; MF.helper; "yes"; rescue; "no"; end))
  line("module_function_instance_stays_public", MF.instance_methods.include?(:helper) ? "yes" : "no")
  # bare module_function is inert (does not affect subsequent defs)
  module MF2; module_function; def a; end; end
  line("module_function_bare_inert", (begin; MF2.a; "no"; rescue NoMethodError; "yes"; end))
  # module_function undef'd on Class
  line("module_function_undef_on_class", (begin; Class.new.send(:module_function, :x); "no"; rescue NoMethodError; "yes"; end))

  # private_constant absent from the language
  line("private_constant_absent", (begin; Class.new.send(:private_constant, :X); "no"; rescue NoMethodError; "yes"; end))
MRB

EXPECT = {
  "undef_blocks_inherited" => "yes",
  "remove_inherited_raises" => "yes",
  "remove_own_reveals_parent" => "p",
  "alias_snapshots" => "first/second",
  "attr_names" => "100111", # r=1 r==0 w=0 w==1 a=1 a==1
  "private_excluded_from_instance_methods" => "yes",
  "private_in_private_instance_methods" => "yes",
  "define_method_public_despite_private" => "yes",
  "module_function_singleton" => "yes",
  "module_function_instance_stays_public" => "yes",
  "module_function_bare_inert" => "yes",
  "module_function_undef_on_class" => "yes",
  "private_constant_absent" => "yes",
}.freeze

Tempfile.create(["mruby_sem", ".rb"]) do |f|
  f.write(SCRIPT)
  f.flush
  out, err, status = Open3.capture3(MRUBY, f.path)
  abort "mruby crashed:\n#{err}" unless status.success?
  got = out.lines.map { |l| l.strip.split("=", 2) }.to_h

  fails = 0
  EXPECT.each do |k, want|
    have = got[k]
    ok = have == want
    fails += 1 unless ok
    puts format("%-4s %-42s %s", ok ? "PASS" : "FAIL", k, ok ? "" : "(got #{have.inspect}, want #{want.inspect})")
  end
  puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"
  exit(fails.zero? ? 0 : 1)
end
