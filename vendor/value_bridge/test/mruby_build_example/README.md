# Reproducing the mruby leg build/test

A worked example of wiring value_bridge into an mruby build and round-tripping.

`vb_test_gem/` is a SEPARATE consumer mrbgem: its `src/driver.c` includes only
the exported `vb_mruby.h` (never ruby.h) and defines `ValueBridge.__roundtrip`,
proving the header-export firewall.

    git clone --depth 1 -b 3.3.0 https://github.com/mruby/mruby
    cd mruby
    # edit build_config.rb paths to point at this gem and vb_test_gem
    MRUBY_CONFIG=/path/to/build_config.rb rake
    ./build/host/bin/mruby /path/to/value_bridge/test/roundtrip_mruby.rb
