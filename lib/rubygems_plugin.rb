# frozen_string_literal: true

# Auto-loaded by RubyGems from this gem's load path. Registers a post-uninstall
# hook so `gem uninstall mruby-lsp` leaves NOTHING behind.
#
# RubyGems removes the per-gem directory and the binstubs it installed, but it
# does NOT know about anything the install hook (ext/mruby_lsp_install) and
# `mruby-lsp-setup` wrote on their own:
#
#   * the compiled launchers + the nonet helper + the impl wrappers the install
#     hook dropped into the recorded bindir (install.json["bin"]). They are NOT
#     declared `spec.executables`, so RubyGems never tracked them — on a layout
#     where that bindir is shared (e.g. Gem.bindir), they would be orphaned.
#   * records written OUTSIDE the gem tree, at FIXED passwd-home paths (never
#     $XDG/$HOME — the same env-free rule used everywhere else so a stray
#     environment can't relocate them):
#       <home>/.local/share/mruby-lsp   install.json + per-workspace setup state
#       <home>/.cache/mruby-lsp         built reflection VMs + reflect.so caches
#
# All of it is removed, but ONLY once the LAST mruby-lsp version is gone, so a
# version upgrade (which uninstalls the previous version) doesn't pull a working
# cache out from under the version that stays.

Gem.post_uninstall do |uninstaller|
  spec = uninstaller.spec
  next unless spec && spec.name == "mruby-lsp"

  # Any other mruby-lsp version still installed? Read the spec dirs straight from
  # disk — the just-removed gemspec is already gone, so no cache reset is needed
  # mid-uninstall. The `[0-9]` guard keeps a differently-named gem that merely
  # shares the prefix (mruby-lsp-foo-*) from counting.
  still_installed = Gem::Specification.dirs.any? do |dir|
    !Dir.glob(File.join(dir, "mruby-lsp-[0-9]*.gemspec")).empty?
  end
  next if still_installed

  require "etc"
  require "fileutils"
  require "json"

  home =
    begin
      Etc.getpwuid(Process.uid).dir
    rescue ArgumentError, SystemCallError
      Dir.home   # last resort only if the uid has no passwd entry
    end
  next if home.to_s.empty?

  data_dir = File.join(home, ".local", "share", "mruby-lsp")

  # 1. The install-hook artifacts RubyGems doesn't track, in the bindir the hook
  #    recorded. Read it from install.json BEFORE removing the record. Delete only
  #    our own EXACT filenames — never a glob: that bindir may be shared.
  record = File.join(data_dir, "install.json")
  if File.file?(record)
    bin =
      begin
        JSON.parse(File.read(record))["bin"]
      rescue JSON::ParserError
        nil
      end
    if bin && File.directory?(bin)
      ext = RbConfig::CONFIG["EXEEXT"]
      %w[mruby-lsp mruby-lsp-setup mruby-lsp-update mruby-lsp-nonet
         mruby-lsp-server mruby-lsp-setup-impl mruby-lsp-update-impl].each do |name|
        path = File.join(bin, "#{name}#{ext}")
        File.delete(path) if File.file?(path)
      end
    end
  end

  # 2. The out-of-tree record + state + build-cache trees.
  [data_dir, File.join(home, ".cache", "mruby-lsp")].each do |dir|
    FileUtils.rm_rf(dir) if File.exist?(dir)
  end

  warn "mruby-lsp: removed launchers, install record, setup state, and build caches"
end
