# mgem (mruby) face of value_bridge.
#
# Role: compile the mruby-safe half into libmruby and EXPORT headers, so a
# consumer can bridge mruby<->{cruby,jruby} without ever pulling a conflicting
# runtime's macros into the same translation unit.
#
# mruby auto-compiles src/*.c (vb.c + vb_names.c + vb_mruby.c -- mruby headers only) and
# mrblib/*.rb (ValueBridge::Tagged). The gem's include/ is added to dependents'
# include path automatically, which is how vb.h and vb_mruby.h get exported.
#
# This gem links NO other runtime. Embedding CRuby/JRuby is the consumer's job,
# in its own single-runtime TUs, composed through the neutral vb_value.
MRuby::Gem::Specification.new("mruby-value-bridge") do |spec|
  spec.license = "MIT"
  spec.authors = ["Asmod4n"]
  spec.summary = "mruby_value <-> neutral vb_value, with exported headers (mruby face)"
  # src/*.c, mrblib/*.rb, and include/ are picked up automatically by mruby.
  # Export the public headers (vb.h, vb_mruby.h, vb_cruby.h, vb_jni.h) so an
  # EXTERNAL consumer linking libmruby -- e.g. mruby-lsp's reflect ext -- can
  # #include them. Plain include/ is inter-gem only; this puts them in the build
  # include tree mruby exposes to dependents and external builds.
  spec.export_include_paths << File.join(spec.dir, "include")

  # PROC tag: an mruby Proc is byte-representable via its irep, so it is allowed.
  # The mruby leg calls mrb_proc_to_irep / mrb_proc_from_irep when this gem is in
  # the build (gated by __has_include); without it, procs raise like any other
  # unrepresentable value.
  spec.add_dependency 'mruby-proc-irep-ext', github: 'Asmod4n/mruby-proc-irep-ext'

  # mruby-platform: name-only edge purely for init ORDER -- its gem_init must run
  # before anything reads Platform::OS/Toolchain. NO source on purpose: conf.gem
  # gemdir: (wrapper_build_config) is what actually puts it in the build; giving a
  # source here would send mruby hunting the mgem list, where this vendored,
  # not-yet-published gem isn't.
  spec.add_dependency 'mruby-platform'


  # Time tag: if mruby-time is in this build, put its public header on our
  # include path so the mruby leg (vb_mruby.c) can __has_include <mruby/time.h>
  # and use the only two functions it exposes -- mrb_time_at / mrb_time_get_tm.
  # Optional and order-tolerant: without mruby-time, Time simply isn't a tag here
  # (mruby has no Time class to begin with). mruby knows only UTC or local time,
  # so the bridge carries [sec, nsec, utc] -- no zones, no offsets.
  time_gem = spec.build.gems.find { |g| g.name == 'mruby-time' }
  if time_gem
    inc = (time_gem.respond_to?(:export_include_paths) && !time_gem.export_include_paths.empty?) ?
            time_gem.export_include_paths : [File.join(time_gem.dir, 'include')]
    spec.cc.include_paths += inc
  end
end
