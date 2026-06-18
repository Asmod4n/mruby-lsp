# frozen_string_literal: true

require "digest"

module MrubyLsp
  # The SHA256 of every native source that feeds the cached build (libmruby +
  # the reflect .so): the reflect ext C/H, value_bridge's mruby + cruby legs,
  # and the wrapper build config (which fixes the gem set). The JRuby header is
  # excluded -- it never compiles here.
  #
  # ONE definition, two callers, so their results are byte-identical:
  #   - rake vscode:vendor_gems embeds it in the extension's manifest.json
  #     (the native code THIS release ships).
  #   - mruby-lsp-setup records it per workspace (the native code that workspace
  #     was last built against) and uses it as the cache-rebuild gate.
  # The extension compares embedded-vs-per-workspace to decide, without running
  # setup, which workspaces a release's native changes have made stale. Being a
  # content hash, it is immune to versions (skipped releases included) and mtimes.
  module NativeFingerprint
    module_function

    # gem_root: the gem's root dir (where vendor/, ext/, share/ live). Both the
    # installed gem and the source tree have this layout, so the same files are
    # hashed in build and at setup.
    def native_files(gem_root)
      [
        File.join(gem_root, "share", "wrapper_build_config.rb"),
        *Dir.glob(File.join(gem_root, "ext", "mruby_reflect", "*.{c,h}")),
        *Dir.glob(File.join(gem_root, "vendor", "value_bridge", "src", "*.{c,h}")),
        *Dir.glob(File.join(gem_root, "vendor", "value_bridge", "cruby", "*.{c,h}")),
        *Dir.glob(File.join(gem_root, "vendor", "value_bridge", "include", "*.h"))
           .reject { |f| File.basename(f) == "vb_jni.h" },
      ].sort.uniq
    end

    def digest(gem_root)
      h = Digest::SHA256.new
      native_files(gem_root).each do |f|
        next unless File.file?(f)
        h.update(File.basename(f))         # name, so a rename is a change
        h.update(Digest::SHA256.file(f).digest)
      end
      h.hexdigest
    end
  end
end
