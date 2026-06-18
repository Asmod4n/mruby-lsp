# mruby-platform: compile-time platform facts exposed to Ruby as constants under
# the Platform module. The #ifdefs in src/platform.c are evaluated by the very
# compiler that builds this gem into libmruby, so the values describe the
# toolchain and OS that produced THIS VM -- the honest source of truth, not a
# runtime guess about the host.
#
# mruby auto-compiles src/*.c and runs test/*.rb. No exported headers, no deps.
MRuby::Gem::Specification.new("mruby-platform") do |spec|
  spec.license = "MIT"
  spec.authors = ["Asmod4n"]
  spec.summary = "Compile-time platform/toolchain facts as Ruby constants (Platform::OS, Platform::Toolchain)"
end
