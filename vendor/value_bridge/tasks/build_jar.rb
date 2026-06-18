# Build lib/value_bridge.jar -- run with JRuby at dev/release time, BEFORE
# `gem build` (the jar ships inside the gem; nothing is compiled at install).
# Mirrors concurrent-ruby: prebuilt jar in the gem, no install-time javac.
#   jruby tasks/build_jar.rb
require "fileutils"
abort "run with JRuby" unless RUBY_ENGINE == "jruby"

root    = File.expand_path("..", __dir__)
src     = File.join(root, "src")
inc     = File.join(root, "include")
javadir = File.join(root, "jruby", "java")
gendir  = File.join(root, "jruby", "build")
libdir  = File.join(root, "lib")
cc      = ENV["CC"] || "cc"

jruby_home = java.lang.System.getProperty("jruby.home")
jruby_jar  = File.join(jruby_home, "lib", "jruby.jar")
abort "jruby.jar not found at #{jruby_jar}" unless File.exist?(jruby_jar)

def sh!(c); puts c; raise "failed: #{c}" unless system(c); end

work = File.join(root, "tmp", "jarbuild"); FileUtils.rm_rf(work); FileUtils.mkdir_p(work)

# 1. project the C tag table into VbTags.java (names+values from C, no hand copy)
gen = File.join(work, "gen_java_tags")
sh! "#{cc} #{File.join(gendir,'gen_java_tags.c')} #{File.join(src,'vb.c')} " \
    "#{File.join(src,'vb_names.c')} -I#{inc} -o #{gen}"
sh! "#{gen} > #{File.join(javadir,'org','valuebridge','VbTags.java')}"

# 2. javac against jruby.jar
classes = File.join(work, "classes"); FileUtils.mkdir_p(classes)
javas = Dir[File.join(javadir,'org','valuebridge','*.java')].join(" ")
sh! "javac -cp #{jruby_jar} -d #{classes} #{javas}"

# 3. jar -> lib/
FileUtils.mkdir_p(libdir)
jar = File.join(libdir, "value_bridge.jar")
sh! "jar cf #{jar} -C #{classes} ."
puts "built #{jar}"
