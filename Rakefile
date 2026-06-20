# frozen_string_literal: true

# NOT bundler/gem_tasks: Bundler::GemHelper reads the gemspec when the Rakefile
# LOADS, so a build prerequisite that rewrote the version would be invisible to
# the build task. We own build/install instead.
#
# VERSIONING IS DELIBERATE. This project ships to users now: lib/mruby_lsp/
# version.rb is the single hand-set SemVer source of truth. NO build, install,
# or package task bumps it. To release a new version, run an EXPLICIT bump:
#   rake bump:patch   # 0.1.120 -> 0.1.121
#   rake bump:minor   # 0.1.120 -> 0.2.0
#   rake bump:major   # 0.1.120 -> 1.0.0
# `rake install` uses `gem install --force`, so the SAME version reinstalls
# cleanly while iterating — no bump needed to test a change.
#
# ONE build/ directory holds everything transient: build/gems (OUR authored
# gems only), build/stage (vsix assembly), and the final .vsix. After any build
# the SOURCE TREE holds source only — no .gem, no .vsix, no fetched deps. `rake
# clobber` removes build/ entirely.

require "fileutils"
require "rake/clean"

VSCODE_DIR = File.join(__dir__, "editors", "vscode")
BUILD_DIR  = File.join(__dir__, "build")
BUILD_GEMS = File.join(BUILD_DIR, "gems")   # our authored gems only
BUILD_STAGE = File.join(BUILD_DIR, "stage") # vsix assembly

VERSION_FILE   = File.join(__dir__, "lib", "mruby_lsp", "version.rb")
VB_VERSION_FILE = File.join(__dir__, "vendor", "value_bridge", "lib", "value_bridge", "version.rb")
MTIMES_FILE    = File.join(__dir__, "share", "mtimes.json")
PACKAGE_JSON   = File.join(VSCODE_DIR, "package.json")

# build/ is the single transient root; remove it (and any per-project mruby
# build under it) with `rake clobber`.
CLOBBER.include("build")
CLOBBER.include("mruby/build")
# rake/clean defines :clobber with a generic desc; re-describe it for `rake -T`.
Rake::Task[:clobber].clear_comments if Rake::Task.task_defined?(:clobber)
desc "Remove all build artifacts (build/ — gems, vsix stage, packaged .vsix)"
task :clobber

def vsce
  local = File.join(VSCODE_DIR, "node_modules", ".bin", "vsce")
  File.executable?(local) ? local : "npx vsce"
end

# vsce binary inside a staged dir (after that stage's own npm install).
# The editor CLI: `code` is NOT necessarily the editor in use -- VSCodium
# ships `codium`, code-oss ships `code-oss`, and a machine can have several.
# Installing through the wrong one "succeeds" while the running editor never
# changes. Auto-detect, overridable via MRUBY_LSP_CODE.
def editor_cli
  @editor_cli ||= ENV["MRUBY_LSP_CODE"] ||
                  %w[codium code-oss code-server code].find { |c| system("command -v #{c} > /dev/null 2>&1") } ||
                  "code"
end

def stage_vsce(stage)
  local = File.join(stage, "node_modules", ".bin", "vsce")
  File.executable?(local) ? local : "npx vsce"
end

# The current, hand-set version — read fresh from version.rb in a child process
# so we never see a constant this rake process loaded earlier.
def current_version
  `#{RbConfig.ruby} -r./lib/mruby_lsp/version -e "print MrubyLsp::VERSION"`.strip
end

def vsix_path
  File.join(BUILD_DIR, "mruby-lsp-#{current_version}.vsix")
end

# Pin value_bridge to mruby-lsp's current version (lockstep). value_bridge and
# mruby-lsp ship as one unit, so one version to reason about and no drift: a
# same-version no-op can never leave a stale value_bridge behind. Rewrites
# vendor/value_bridge/lib/value_bridge/version.rb in place. Returns the version.
def pin_value_bridge(version)
  File.write(VB_VERSION_FILE, <<~RUBY)
    # frozen_string_literal: true

    module ValueBridge
      VERSION = "#{version}"
    end
  RUBY
  version
end

namespace :gem do
  # Record every shipped file's mtime. `gem install` stamps fresh mtimes on
  # extraction, which made mruby's mtime-driven build rebuild EVERYTHING after
  # every reinstall of byte-identical files; mruby-lsp-setup restores these
  # stamps (File.utime) before building, so unchanged content stays a no-op.
  desc "Write share/mtimes.json for all gem files"
  task :mtimes do
    require "json"
    Dir.chdir(__dir__) do
      spec = Gem::Specification.load("mruby-lsp.gemspec")
      stamps = {}
      spec.files.sort.each do |f|
        next if f == "share/mtimes.json" # not its own subject
        stamps[f] = File.mtime(f).to_i if File.file?(f)
      end
      File.write(MTIMES_FILE, JSON.pretty_generate(stamps) + "\n")
      puts "recorded #{stamps.size} mtimes -> share/mtimes.json"
    end
  end

  # ONE shared gem build (NO bump). Builds BOTH authored gems at the CURRENT
  # version into build/gems/. install/package both depend on this and only
  # differ in where they put the result.
  desc "Build the authored gems (mruby-lsp + value_bridge) into build/gems/ at the current version"
  task :build do
    Dir.chdir(__dir__) do
      version = current_version

      # 1. Pin value_bridge to mruby-lsp's version (lockstep) BEFORE recording
      #    mtimes, so the pinned version.rb's fresh mtime is what gets recorded.
      pin_value_bridge(version)

      # 2. Record mtimes AFTER the pin (the pinned file is part of the gem).
      Rake::Task["gem:mtimes"].invoke

      # 3. Build both gems into build/gems/. NO bump: the same version
      #    overwrites cleanly.
      FileUtils.mkdir_p(BUILD_GEMS)
      sh "gem build mruby-lsp.gemspec --output #{File.join(BUILD_GEMS, "mruby-lsp-#{version}.gem")}"
      Dir.chdir(File.join("vendor", "value_bridge")) do
        sh "gem build value_bridge.gemspec --output #{File.join(BUILD_GEMS, "value_bridge-#{version}.gem")}"
      end
      puts "built build/gems/{mruby-lsp,value_bridge}-#{version}.gem"
    end
  end

  desc "Build and install the authored gems from build/gems/ (same-version overwrite via --force)"
  task install: :build do
    Dir.chdir(__dir__) do
      version = current_version

      # Root installs into the system gem home; an unprivileged user can't write
      # there, so fall back to `--user-install` (Gem.user_dir, always writable).
      # The install hook records whichever bindir RubyGems used (it makes the same
      # root check), so discovery + uninstall follow automatically. Same flag for
      # BOTH gems so mruby-lsp's `add_dependency "value_bridge"` resolves in the
      # one gem home this install populated.
      user_flag = Process.uid.zero? ? "" : " --user-install"

      vb_gem = File.join(BUILD_GEMS, "value_bridge-#{version}.gem")
      ml_gem = File.join(BUILD_GEMS, "mruby-lsp-#{version}.gem")

      # value_bridge FIRST: it is local with no remote deps, so install it from
      # the file with --local. --force overwrites a same-version install (dev
      # iterates without bumping).
      sh "gem install#{user_flag} --local --force #{vb_gem}"

      # mruby-lsp WITHOUT --local: its EXTERNAL deps (prism, rbs,
      # language_server-protocol) resolve from rubygems and value_bridge resolves
      # to the just-installed local one. --force overwrites a same-version install.
      sh "gem install#{user_flag} --force #{ml_gem}"
    end
  end

  desc "Uninstall the authored gems (the post-uninstall hook clears launchers + caches)"
  task :uninstall do
    # mruby-lsp FIRST: its post-uninstall hook (lib/rubygems_plugin.rb) removes
    # the launchers, the nonet helper, install.json, setup state, and the build
    # caches once the LAST version is gone. value_bridge after — by then nothing
    # depends on it. --all every version; --executables drops any launcher slot
    # without a prompt; --force skips the dependency/confirm prompts; `|| true`
    # keeps "not installed" from failing the task.
    %w[mruby-lsp value_bridge].each do |g|
      sh "gem uninstall --all --executables --force #{g} || true"
    end
  end
end

# ── Explicit, deliberate version bumps ──────────────────────────────────────
# These are the ONLY tasks that change the version. They are NOT prerequisites
# of any build/install task. Each writes version.rb + package.json and pins
# value_bridge in lockstep.
namespace :bump do
  def write_version(new_version)
    require "json"
    File.write(VERSION_FILE, <<~RUBY)
      # frozen_string_literal: true

      module MrubyLsp
        VERSION = "#{new_version}"
      end
    RUBY
    data = JSON.parse(File.read(PACKAGE_JSON))
    data["version"] = new_version
    File.write(PACKAGE_JSON, JSON.pretty_generate(data) + "\n")
    pin_value_bridge(new_version)
    new_version
  end

  # Patch: increment the trailing integer (0.1.120 -> 0.1.121), like the old
  # auto-bump. Preserves the XDG version-record/high-water-mark recovery: the
  # tree is disposable and gems get uninstalled, so the released version is also
  # RECORDED in XDG data; the base is the max of every source available.
  desc "Bump the patch version (x.y.Z -> x.y.Z+1) — gem + vscode, lockstep value_bridge"
  task :patch do
    require "json"
    require_relative "lib/mruby_lsp/version"
    state_dir = File.join(ENV["XDG_DATA_HOME"] || File.join(Dir.home, ".local", "share"), "mruby-lsp")
    state = File.join(state_dir, "version.json")
    sources = [Gem::Version.new(MrubyLsp::VERSION)]
    sources += Gem::Specification.find_all_by_name("mruby-lsp").map(&:version)
    if File.exist?(state)
      v = (JSON.parse(File.read(state))["version"] rescue nil)
      sources << Gem::Version.new(v) if v
    end
    ext = (`#{editor_cli} --list-extensions --show-versions 2>/dev/null`[/asmod4n\.mruby-lsp@(\S+)/, 1] rescue nil)
    sources << Gem::Version.new(ext) if ext
    old = sources.max.to_s
    digits = old[/\d+\z/] or abort "version #{old.inspect} has no trailing integer"
    new_version = old[0...-digits.length] + (digits.to_i + 1).to_s
    write_version(new_version)
    FileUtils.mkdir_p(state_dir)
    File.write(state, JSON.pretty_generate({ "version" => new_version }) + "\n")
    puts "version #{old} -> #{new_version} (gem + vscode + value_bridge, recorded)"
  end

  # Minor: increment the middle segment, reset patch to 0 (0.1.120 -> 0.2.0).
  desc "Bump the minor version (x.Y.z -> x.Y+1.0) — gem + vscode, lockstep value_bridge"
  task :minor do
    require_relative "lib/mruby_lsp/version"
    old = MrubyLsp::VERSION
    parts = old.split(".")
    abort "version #{old.inspect} is not x.y.z" unless parts.length == 3
    new_version = "#{parts[0]}.#{parts[1].to_i + 1}.0"
    write_version(new_version)
    puts "version #{old} -> #{new_version} (gem + vscode + value_bridge)"
  end

  # Major: increment the leading segment, reset minor + patch to 0
  # (0.1.120 -> 1.0.0).
  desc "Bump the major version (X.y.z -> X+1.0.0) — gem + vscode, lockstep value_bridge"
  task :major do
    require_relative "lib/mruby_lsp/version"
    old = MrubyLsp::VERSION
    parts = old.split(".")
    abort "version #{old.inspect} is not x.y.z" unless parts.length == 3
    new_version = "#{parts[0].to_i + 1}.0.0"
    write_version(new_version)
    puts "version #{old} -> #{new_version} (gem + vscode + value_bridge)"
  end
end

desc "Build the authored gems into build/gems/ (current version, no bump)"
task build: "gem:build"

desc "Build and install the authored gems (same-version overwrite, no bump)"
task install: "gem:install"

desc "Uninstall the authored gems (clears launchers, install record, and caches)"
task uninstall: "gem:uninstall"

namespace :vscode do
  desc "Install JS deps for the VS Code extension"
  task :deps do
    Dir.chdir(VSCODE_DIR) { sh "npm install" }
  end

  desc "Compile the extension (tsc)"
  task compile: :deps do
    Dir.chdir(VSCODE_DIR) { sh "npm run compile" }
  end

  # Stage the extension source into BUILD_STAGE: exclude
  # node_modules/out/*.vsix/.vscode-test/.installed-lock, preserve mtimes (the
  # source on-disk stamps are exactly what gem:mtimes recorded, so they pack into
  # the .vsix unchanged), and keep the cached node_modules across runs (it is
  # excluded from both transfer and --delete). rsync is a documented packaging
  # prerequisite (CONTRIBUTING; `pkg install rsync` on FreeBSD).
  def stage_sources(src, dst)
    sh "rsync", "-a", "--delete",
       "--exclude=node_modules", "--exclude=out", "--exclude=*.vsix",
       "--exclude=.vscode-test", "--exclude=.installed-lock",
       "#{src}/", "#{dst}/"
  end

  # Fetch the FULL external runtime-dependency CLOSURE of the server gem as
  # portable source .gem files DIRECTLY into the stage's vendor/gems, then write
  # the manifest (versions + native fingerprint + bundle digest). The authored
  # gems are COPIED from build/gems (built once by gem:build — NOT rebuilt here;
  # that is the drift fix). The fetched externals live ONLY in the stage: never
  # in build/gems, never in the repo.
  def assemble_bundle(gemsdir, version)
    require "json"
    require "rubygems"
    require "rubygems/package"
    require "digest"
    require "tmpdir"

    FileUtils.mkdir_p(gemsdir)
    manifest = {}

    # 1. Copy the already-built authored gems into the stage (do NOT rebuild).
    %w[mruby-lsp value_bridge].each do |name|
      src = File.join(BUILD_GEMS, "#{name}-#{version}.gem")
      abort "vscode:package: #{src} not found — run gem:build first" unless File.exist?(src)
      FileUtils.cp(src, File.join(gemsdir, "#{name}-#{version}.gem"), preserve: true)
      manifest[name] = version
    end

    # 2. Fetch the FULL external runtime-dependency closure. `gem fetch <name>`
    #    pulls only the named gem (never its transitive deps), so a direct-deps
    #    vendor ships rbs but leaves rbs's own logger/tsort out — and a
    #    bundle-only GEM_PATH can't fall back to a default gem for them (logger
    #    stopped being a default gem in Ruby 4.0). Walk the graph breadth-first.
    #    --platform ruby pulls the SOURCE gem (cross-platform; native exts compile
    #    at install). Content-stable: rubygems serves the same immutable bytes for
    #    a version, so skip-if-same-SHA leaves an unchanged .gem (and its mtime)
    #    untouched. Authored gems are copied above; skip them wherever they appear.
    gem_exe = File.join(RbConfig::CONFIG["bindir"], "gem#{RbConfig::CONFIG["EXEEXT"]}")
    gem_exe = "gem" unless File.exist?(gem_exe)
    spec = Gem::Specification.load(File.join(__dir__, "mruby-lsp.gemspec"))

    ours  = %w[mruby-lsp value_bridge]
    seen  = {}
    keep  = []
    queue = spec.runtime_dependencies
                .reject { |d| ours.include?(d.name) }
                .map    { |d| [d.name, d.requirement.as_list.join(", ")] }

    Dir.mktmpdir do |tmp|
      until queue.empty?
        name, req = queue.shift
        next if ours.include?(name) || seen[name]
        seen[name] = true

        # Fetch each gem into its OWN subdir so the *.gem glob can't pick up a
        # name-prefixed sibling (e.g. logger vs language_server-protocol).
        sub = File.join(tmp, name.gsub(/[^\w.-]/, "_"))
        FileUtils.mkdir_p(sub)
        ok = system(gem_exe, "fetch", name,
                    "--platform", "ruby", "--version", req, "--quiet", chdir: sub)
        abort "vscode:package: `gem fetch #{name} -v '#{req}'` failed " \
              "(no network, or wrong name/version?)" unless ok

        fetched = Dir.glob(File.join(sub, "*.gem")).max_by { |f| File.mtime(f) }
        abort "vscode:package: gem fetch produced no source .gem for #{name}" unless fetched

        dep_spec = Gem::Package.new(fetched).spec
        fname = File.basename(fetched)
        dst   = File.join(gemsdir, fname)
        same  = File.exist?(dst) && Digest::SHA256.file(dst) == Digest::SHA256.file(fetched)
        FileUtils.cp(fetched, dst, preserve: true) unless same
        keep << fname
        manifest[name] = dep_spec.version.to_s

        dep_spec.runtime_dependencies.each do |d|
          queue << [d.name, d.requirement.as_list.join(", ")] \
            unless seen[d.name] || ours.include?(d.name)
        end
      end
    end

    # Prune stale external .gem files from previous versions so the vendor dir
    # holds exactly the current external set. (Authored gems are kept by name.)
    authored = %w[mruby-lsp value_bridge].map { |n| "#{n}-#{version}.gem" }
    Dir.glob(File.join(gemsdir, "*.gem")).each do |f|
      base = File.basename(f)
      File.delete(f) unless keep.include?(base) || authored.include?(base)
    end

    # Embed the native fingerprint of THIS release: the hash of every C source
    # that feeds the cached build, via the SAME helper setup uses. The extension
    # compares it against each workspace's recorded `native` to decide, WITHOUT
    # running setup, which workspaces a native change has made stale.
    require_relative "lib/mruby_lsp/native_fingerprint"
    manifest["native"] = MrubyLsp::NativeFingerprint.digest(__dir__)

    # The `bundle` digest: SHA256 over the sorted list of
    # "<filename>:<sha256-of-bytes>" for EVERY .gem in the stage. This is the
    # CONTENT-based reinstall trigger — the extension reinstalls iff this changes,
    # independent of the SemVer.
    entries = Dir.glob(File.join(gemsdir, "*.gem")).map do |f|
      "#{File.basename(f)}:#{Digest::SHA256.file(f).hexdigest}"
    end.sort
    manifest["bundle"] = Digest::SHA256.hexdigest(entries.join("\n"))

    File.write(File.join(gemsdir, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
    puts "assembled #{manifest.size - 2} gems into #{gemsdir} (bundle #{manifest["bundle"][0, 12]}…):"
    manifest.each { |n, v| puts "    #{n} #{v}" unless %w[native bundle].include?(n) }
  end

  # Package the .vsix from the SHARED gem build. Depends on gem:build (built
  # once); this assembles, never rebuilds the authored gems. The source
  # editors/vscode/vendor/gems/ is NOT written to — the bundle lives only in the
  # stage and the .vsix.
  desc "Package the .vsix into build/ (assembles bundle from build/gems + fetched externals)"
  task package: "gem:build" do
    require "json"

    version = current_version
    final_vsix = File.join(BUILD_DIR, "mruby-lsp-#{version}.vsix")
    FileUtils.mkdir_p(BUILD_DIR)

    # PERSISTENT stage under build/ (moved OUT of the XDG cache): node_modules
    # survives across runs and npm only runs when package-lock.json changed.
    stage = BUILD_STAGE
    FileUtils.mkdir_p(stage)

    # Mirror the SOURCE into the stage preserving mtimes; node_modules excluded
    # from transfer and delete so the cached install survives.
    stage_sources(VSCODE_DIR, stage)

    # The repo LICENSE is the single source; vsce packs only what's in the stage
    # and warns/prompts without one.
    FileUtils.cp(File.join(__dir__, "LICENSE"), File.join(stage, "LICENSE"))

    # Assemble the bundle straight into the stage: copy the already-built
    # authored gems from build/gems, fetch the external closure here, write the
    # manifest with the bundle digest. Never touches the repo tree.
    assemble_bundle(File.join(stage, "vendor", "gems"), version)

    Dir.chdir(stage) do
      # Deterministic, lock-driven, quiet. Skipped when the lock that built the
      # cached node_modules is byte-identical to the current one.
      marker = ".installed-lock"
      lock = "package-lock.json"
      if !File.directory?("node_modules") || !File.exist?(marker) || !FileUtils.identical?(lock, marker)
        # --ignore-scripts: the only packages here with install scripts are
        # @vscode/vsce's signing helpers (@vscode/vsce-sign postinstall fetches
        # native binaries with NO FreeBSD build and ABORTS there; keytar needs
        # libsecret + node-gyp). `vsce package` needs neither, and we sign via
        # node-ovsx-sign below. Skipping lifecycle scripts is safe on every OS and
        # unblocks FreeBSD packaging.
        sh "npm install --no-audit --no-fund --loglevel=error --ignore-scripts"
        FileUtils.cp(lock, marker)
      else
        puts "    deps up to date, skipping npm install"
      end
      # Compile in-stage (out/extension.js is a fresh artifact, mtime = build).
      sh "npm run compile"
      # vsce preserves the mtimes of what it packs; the stage carries the real
      # source mtimes, so they pass through into the vsix unchanged.
      sh "#{stage_vsce(stage)} package --no-git-tag-version --allow-missing-repository --out mruby-lsp-#{version}.vsix"
    end

    # Move the result into build/, preserving its mtime.
    FileUtils.cp(File.join(stage, "mruby-lsp-#{version}.vsix"), final_vsix, preserve: true)
    File.delete(File.join(stage, "mruby-lsp-#{version}.vsix"))

    # Signing-ready (Open VSX style via node-ovsx-sign — pure JS, works on
    # FreeBSD &c.). Opt-in: only signs when a PKCS#8 key is configured. Set
    # MRUBY_LSP_VSIX_SIGN_KEY=/path/to/key.pem to emit <vsix>.sig + .manifest.
    if (key = ENV["MRUBY_LSP_VSIX_SIGN_KEY"].to_s).empty?
      puts "packaged #{final_vsix} (unsigned; set MRUBY_LSP_VSIX_SIGN_KEY to sign)"
    else
      sh "npx", "--yes", "node-ovsx-sign", "sign", final_vsix, key
      puts "packaged + signed #{final_vsix}"
    end
  end

  desc "Verify the packaged .vsix has the pieces that silently break activation"
  task verify: :package do
    require "json"
    vsix = vsix_path
    list = `unzip -l #{vsix}`

    checks = {
      "out/extension.js present"      => list.include?("extension/out/extension.js"),
      "vscode-languageclient bundled" => list.include?("vscode-languageclient/node.js"),
      "vendored gems present"         => list.include?("extension/vendor/gems/"),
      "bundle manifest present"       => list.include?("extension/vendor/gems/manifest.json"),
    }
    manifest = JSON.parse(`unzip -p #{vsix} extension/package.json`)
    declared = manifest["contributes"]["commands"].map { |c| c["command"] }.sort
    js = `unzip -p #{vsix} extension/out/extension.js`.force_encoding("UTF-8")
    registered = js.scan(/registerCommand\("([^"]+)"/).flatten.sort
    checks["declared commands == registered"] = (declared == registered)

    gem_manifest = JSON.parse(`unzip -p #{vsix} extension/vendor/gems/manifest.json`)
    checks["manifest carries bundle digest"] = !gem_manifest["bundle"].to_s.empty?

    checks.each { |name, ok| puts "  #{ok ? 'ok ' : 'FAIL'}  #{name}" }
    failed = checks.reject { |_, ok| ok }
    abort "vsix verification failed: #{failed.keys.join(', ')}" unless failed.empty?
    puts "vsix verified"
  end

  desc "Build, package, and install the extension into VS Code (clean reinstall, no bump)"
  task :install do
    abort "editor CLI '#{editor_cli}' not found on PATH" unless system("command -v #{editor_cli} > /dev/null 2>&1")

    require "json"
    pkg = JSON.parse(File.read(PACKAGE_JSON))
    # VS Code lowercases the publisher in the extension ID.
    ext_id = "#{pkg['publisher'].downcase}.#{pkg['name']}"

    # Uninstall any existing copy FIRST. VS Code can otherwise keep a stale
    # extension dir while registering the new version's metadata, so you end up
    # running old code under a new version number. A clean uninstall guarantees
    # the next install is what actually loads.
    sh "#{editor_cli} --uninstall-extension #{ext_id} || true"

    Rake::Task["vscode:package"].invoke
    vsix = vsix_path
    abort "vsix not found: #{vsix}" unless File.exist?(vsix)
    sh "#{editor_cli} --install-extension #{vsix} --force"

    version = current_version
    puts ""
    puts "installed #{ext_id} #{version}."
    puts "RELOAD the VS Code window now: Command Palette -> 'Developer: Reload Window'"
    puts "(activation-event changes only take effect after a reload)."
  end
end

desc "Build, verify, and install the VS Code extension"
task test: "vscode:verify" do
  Rake::Task["vscode:install"].invoke
end

task default: %i[test]
