require 'mkmf'

# Build flags come from mruby-config (portable -- no `make`, works under MSVC).
# After `rake`, its --cflags carries every gem's EXPORTED include path
# (export_include_paths), so value_bridge's vb*.h and c-ext-helpers' num_helpers.h
# are all on the path with no per-gem -I here. NOTE: editing any gem's mrbgem.rake
# (e.g. adding export_include_paths) requires rerunning rake to regenerate this
# mruby-config binary with the new paths. We compile/link through mruby's own
# cc/cxx/ld (g++) so the C++ objects in libmruby.a resolve their runtime.
mruby = ENV['MRUBY_DIR'] or abort "set MRUBY_DIR"
build = ENV['MRUBY_BUILD']
build = File.join(mruby, 'build', 'host') unless build && File.directory?(build)
mruby_config = File.join(build, 'bin', 'mruby-config')
abort "mruby-config not found: #{mruby_config}" unless File.executable?(mruby_config)
# Run mruby-config WITHOUT a shell (array-form IO.popen): `cfg` is a build path
# derived from the workspace (MRUBY_DIR/MRUBY_BUILD), so a path with shell
# metacharacters must never reach a shell. Args are single flags (--cflags etc.).
def mc(cfg, arg) = IO.popen([cfg, arg], &:read).to_s.strip

cc  = mc(mruby_config, '--cc'); cxx = mc(mruby_config, '--cxx'); ld = mc(mruby_config, '--ld')
RbConfig::MAKEFILE_CONFIG['CC']         = cc  unless cc.empty?
RbConfig::MAKEFILE_CONFIG['CXX']        = cxx unless cxx.empty?
RbConfig::MAKEFILE_CONFIG['LDSHARED']   = "#{ld} -shared" unless ld.empty?
RbConfig::MAKEFILE_CONFIG['LDSHAREDXX'] = "#{ld} -shared" unless ld.empty?
$CFLAGS   << " #{mc(mruby_config, '--cflags')}"
$CXXFLAGS << " #{mc(mruby_config, '--cxxflags')}"
$LDFLAGS  << " #{mc(mruby_config, '--ldflags-before-libs')}"
libmruby = mc(mruby_config, '--libmruby-path')
$LDFLAGS  << " -L#{File.dirname(libmruby)}" unless libmruby.empty?
$LIBS     << " #{mc(mruby_config, '--libs')}"

# value_bridge's CRuby leg is SOURCE we compile into this ext (its mruby leg +
# neutral core are already in libmruby via the mgem). Headers arrive via the
# exported include path above; we only need the .c file -- from the installed
# CRuby gem, or VALUE_BRIDGE_DIR for an unpublished local checkout.
# value_bridge's CRuby leg is SOURCE we compile into this ext (its mruby leg +
# neutral core are already in libmruby via the mgem). It is VENDORED in this
# gem at vendor/value_bridge and ships inside it, so the path is fixed:
# ext/mruby_reflect -> ../../vendor/value_bridge. VALUE_BRIDGE_DIR still
# overrides (e.g. to develop against an out-of-tree checkout); the installed
# value_bridge gem is the last-resort fallback.
vb_dir = ENV['VALUE_BRIDGE_DIR']
vb_dir ||= File.expand_path('../../vendor/value_bridge', __dir__)
unless vb_dir && File.directory?(vb_dir)
  begin require 'value_bridge'; rescue LoadError; end
  begin vb_dir = Gem::Specification.find_by_name('value_bridge').gem_dir
  rescue StandardError; vb_dir = nil end
end
abort "value_bridge cruby leg not found (looked in vendor/value_bridge, VALUE_BRIDGE_DIR, installed gem)" unless
  vb_dir && File.file?(File.join(vb_dir, 'cruby', 'vb_cruby.c'))

# Stage vb_cruby.c NEXT TO extconf rather than reaching it via $VPATH. vb_dir is
# the installed value_bridge gem, whose path can contain spaces (installed under
# "Code - OSS/.../globalStorage"). mkmf puts $VPATH verbatim into the Makefile,
# and make's VPATH does not survive a spaced entry -> the source isn't found and
# vb_cruby.o is never built, so the link fails ("vb_cruby.o not found"). Copying
# it in makes the path relative and space-proof.
require 'fileutils'
FileUtils.cp(File.join(vb_dir, 'cruby', 'vb_cruby.c'), File.join(__dir__, 'vb_cruby.c'))
$srcs = %w[bridge_tu.c mruby_tu.c vb_cruby.c]

create_makefile('mruby_reflect')
