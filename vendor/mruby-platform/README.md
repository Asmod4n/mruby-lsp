# mruby-platform

Compile-time platform facts, exposed to Ruby as constants and baked in by the
compiler that builds mruby -- not guessed at runtime. The values reflect the
toolchain and OS that actually produced the VM.

```ruby
Platform::OS         # => :linux | :macos | :windows | :unknown
Platform::Toolchain  # => :gcc | :clang | :msvc | :unknown
```

## Build

Add it to your `build_config.rb`:

```ruby
conf.gem '/path/to/mruby-platform'
# or
conf.gem github: 'Asmod4n/mruby-platform'
```

`src/platform.c` is compiled automatically. There are no dependencies and no
exported headers.
