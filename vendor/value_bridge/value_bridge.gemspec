# frozen_string_literal: true

require_relative "lib/value_bridge/version"

Gem::Specification.new do |spec|
  spec.name        = "value_bridge"
  spec.version     = ValueBridge::VERSION
  spec.authors     = ["Asmod4n"]
  spec.summary     = "Direct value bridging between mruby, CRuby, and JRuby"
  spec.description = "A neutral tagged-value interchange and per-runtime converters " \
                     "(mruby, CRuby, JRuby) that pass Ruby values between runtimes with " \
                     "no JSON/CBOR/marshal in between."
  spec.homepage    = "https://github.com/Asmod4n/value_bridge"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  # vb.h is the single source of truth for the tag set; it ships in every build
  # so all three legs include the same header. The names live once in
  # src/vb_names.c (string literals in .rodata) and are queried, never recopied.
  common = Dir.glob("lib/**/*.rb") + Dir.glob("include/*.h") + %w[README.md LICENSE]

  if RUBY_ENGINE == "jruby" || RUBY_PLATFORM == "java"
    # Java-platform gem: the JRuby leg. Like concurrent-ruby, the jar is built
    # ahead of release (tasks/build_jar.rb) and SHIPPED in the gem -- nothing is
    # compiled at install, so no JDK/javac is needed by the user and the gem is
    # architecture-independent. The native JNI seam (jruby/native/vb_jni.c) ships
    # as SOURCE for hosts that embed a native runtime; it is not prebuilt (an
    # arch-specific .so would break the "java" platform), and not an extension.
    spec.platform   = "java"
    spec.files      = common +
                      ["lib/value_bridge.jar"] +          # prebuilt, shipped
                      Dir.glob("include/*.h") +
                      Dir.glob("src/*.c") +                # shared core, for integrators
                      Dir.glob("jruby/**/*.{java,c}") +    # Java leg + JNI seam (source)
                      Dir.glob("jruby/build/*.c") +
                      ["tasks/build_jar.rb"]
      .uniq
    spec.extensions = []                                   # no install-time build
  else
    # Default (MRI) gem: the CRuby leg. Builds the neutral core + CRuby leg at
    # install; the mruby leg is added by extconf only when mruby-config is found.
    spec.files      = common +
                      Dir.glob("ext/**/*.{rb,c,h}") +
                      Dir.glob("src/*.c") +
                      Dir.glob("cruby/*.c")
    spec.extensions = ["ext/value_bridge/extconf.rb"]
  end
end
