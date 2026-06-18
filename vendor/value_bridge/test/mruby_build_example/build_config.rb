MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gembox 'default'                 # includes mruby-metaprog, mruby-class-ext, etc.
  conf.gem File.expand_path('/home/claude/value_bridge')  # gem under test (mgem face)
  conf.gem File.expand_path('/tmp/vb_test_gem')           # separate consumer
  conf.enable_debug
end
