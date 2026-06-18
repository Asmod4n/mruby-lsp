# frozen_string_literal: true

require_relative "value_bridge/version"
require_relative "value_bridge/tagged"

# value_bridge converts a Ruby value from one runtime to another and back. The
# tag set and codecs are internal; the only public surface is the per-runtime
# producer/consumer plus the Tagged carrier for values beyond the floor.
if RUBY_ENGINE == "jruby"
  # The Java leg ships as a jar built into lib/; loading it puts org.valuebridge.*
  # on the classpath. The JNI seam (libvalue_bridge_jni.*) is loaded explicitly
  # by an embedding host via VbNative.load only when bridging to a native
  # runtime -- pure JRuby value work needs just the jar.
  require "java"
  # Require by bare name so JRuby resolves it on the gem's load path (lib/) and
  # actually adds it to the classpath -- an absolute-path jar require nested in
  # the gem load is not reliably picked up. (Same approach as concurrent-ruby.)
  require "value_bridge.jar"
else
  # CRuby: the C extension provides VALUE <-> vb_value (and mrb_value <-> vb_value
  # when linked against a libmruby found via mruby-config at build time).
  begin
    require_relative "value_bridge/value_bridge_ext"
  rescue LoadError
    # Consumers that link the C library directly don't need the prebuilt ext;
    # the Ruby API (Tagged) works without it.
  end
end

module ValueBridge
end
