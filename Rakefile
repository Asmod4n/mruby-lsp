# frozen_string_literal: true

# NOT bundler/gem_tasks: Bundler::GemHelper reads the gemspec when the Rakefile
# LOADS, so a version bump running as a prerequisite is invisible to its build
# task -- `rake install` shipped the OLD version. We own build/install instead;
# every publish path goes through gem:build and therefore bumps.

VSCODE_DIR = File.join(__dir__, "editors", "vscode")

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
                  %w[codium code-oss code].find { |c| system("command -v #{c} > /dev/null 2>&1") } ||
                  "code"
end

def stage_vsce(stage)
  local = File.join(stage, "node_modules", ".bin", "vsce")
  File.executable?(local) ? local : "npx vsce"
end

def vsix_path
  require "json"
  version = JSON.parse(File.read(File.join(VSCODE_DIR, "package.json")))["version"]
  File.join(VSCODE_DIR, "mruby-lsp-#{version}.vsix")
end

namespace :gem do
  VERSION_FILE = File.join(__dir__, "lib", "mruby_lsp", "version.rb")
  MTIMES_FILE  = File.join(__dir__, "share", "mtimes.json")

  # ONE version for everything, pre-1.0 scheme: plain x.y.z, bump = last digit
  # +1 (0.1.4 -> 0.1.5). Writes BOTH version.rb (gem) and the vscode extension
  # package.json -- the artifacts always carry the same number. 1.0.0 is a
  # hand edit when it's earned.
  desc "Bump the shared version (gem + vscode extension)"
  task :bump do
    require "json"
    # Register the `ours` merge driver this clone needs for the merge=ours
    # entries in .gitattributes (generated/version files never conflict on merge).
    # Local to this clone, idempotent — safe to run on every build.
    system("git", "config", "merge.ours.driver", "true") if File.directory?(".git")
    require_relative "lib/mruby_lsp/version"
    # The tree is DISPOSABLE (delete-and-unzip resets version.rb) and gems get
    # uninstalled, so neither is a reliable high-water mark. The released
    # version is RECORDED in XDG data (survives both); the bump bases on the
    # max of every source available: the record, the tree, installed gems, and
    # the installed VS Code extension.
    state_dir = File.join(ENV["XDG_DATA_HOME"] || File.join(Dir.home, ".local", "share"), "mruby-lsp")
    state = File.join(state_dir, "version.json")
    sources = [Gem::Version.new(MrubyLsp::VERSION)]
    sources += Gem::Specification.find_all_by_name("mruby-lsp").map(&:version)
    if File.exist?(state)
      v = JSON.parse(File.read(state))["version"] rescue nil
      sources << Gem::Version.new(v) if v
    end
    ext = (`#{editor_cli} --list-extensions --show-versions 2>/dev/null`[/asmod4n\.mruby-lsp@(\S+)/, 1] rescue nil)
    sources << Gem::Version.new(ext) if ext
    old = sources.max.to_s
    digits = old[/\d+\z/] or abort "version #{old.inspect} has no trailing integer"
    new_version = old[0...-digits.length] + (digits.to_i + 1).to_s
    File.write(VERSION_FILE, <<~RUBY)
      # frozen_string_literal: true

      module MrubyLsp
        VERSION = "#{new_version}"
      end
    RUBY
    pkg = File.join(VSCODE_DIR, "package.json")
    data = JSON.parse(File.read(pkg))
    data["version"] = new_version
    File.write(pkg, JSON.pretty_generate(data) + "\n")
    FileUtils.mkdir_p(state_dir)
    File.write(state, JSON.pretty_generate({ "version" => new_version }) + "\n")
    puts "version #{old} -> #{new_version} (gem + vscode, recorded)"
  end

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

  desc "Bump version, record mtimes, build the gem into pkg/"
  task build: %i[bump mtimes] do
    Dir.chdir(__dir__) do
      FileUtils.mkdir_p("pkg")
      # Fresh process: the bumped version.rb must be re-read, not the constant
      # this rake process loaded before the bump.
      version = `#{RbConfig.ruby} -r./lib/mruby_lsp/version -e "print MrubyLsp::VERSION"`
      sh "gem build mruby-lsp.gemspec --output pkg/mruby-lsp-#{version}.gem"
      puts "built pkg/mruby-lsp-#{version}.gem"
    end
  end

  desc "Build (auto-bumps) and install the gem"
  task install: :build do
    Dir.chdir(__dir__) do
      # Root installs into the system gem home; an unprivileged user can't write
      # there, so fall back to `--user-install` (Gem.user_dir, always writable).
      # The install hook records whichever bindir RubyGems used (it makes the same
      # root check), so discovery + uninstall follow automatically. Same flag for
      # BOTH gems so mruby-lsp's `add_dependency "value_bridge"` resolves in the
      # one gem home this install populated.
      user_flag = Process.uid.zero? ? "" : " --user-install"

      # Internal dependency: build + install the vendored value_bridge gem first
      # so mruby-lsp's `add_dependency "value_bridge"` resolves locally -- no
      # Gemfile, not published. Same source the mruby build + reflect ext use.
      # Its CRuby extension builds against ruby.h alone (mruby leg is optional),
      # so this install is self-contained. Reinstalling the same version is fine.
      Dir.chdir("vendor/value_bridge") do
        require "fileutils"
        FileUtils.mkdir_p("pkg")
        vbver = `#{RbConfig.ruby} -r./lib/value_bridge/version -e "print ValueBridge::VERSION"`
        sh "gem build value_bridge.gemspec --output pkg/value_bridge-#{vbver}.gem"
        sh "gem install#{user_flag} pkg/value_bridge-#{vbver}.gem"
      end

      version = `#{RbConfig.ruby} -r./lib/mruby_lsp/version -e "print MrubyLsp::VERSION"`
      sh "gem install#{user_flag} pkg/mruby-lsp-#{version}.gem"
    end
  end
end

require "fileutils"

desc "Build the gem (bumps version, records mtimes)"
task build: "gem:build"

desc "Build and install the gem (bumps version)"
task install: "gem:install"

namespace :vscode do
  desc "Install JS deps for the VS Code extension"
  task :deps do
    Dir.chdir(VSCODE_DIR) { sh "npm install" }
  end

  desc "Compile the extension (tsc)"
  task compile: :deps do
    Dir.chdir(VSCODE_DIR) { sh "npm run compile" }
  end

  # No bump here: versioning is the GEM side's job (gem:bump writes both
  # version.rb and package.json; rake install runs it). This packages whatever
  # version is current. Same-version reinstalls are safe -- vscode:install
  # uninstalls first.
  desc "Package the .vsix (staged in a clean tmpdir, fresh deps, mtimes preserved)"
  # Collect every gem the server needs into editors/vscode/vendor/gems/ as .gem
  # files, so the .vsix is self-contained: the extension installs them offline
  # (gem install --local) into its own storage and launches the server with a
  # GEM_PATH pointing there -- no rubygems.org, no user-side `gem install`, the
  # exact versions we tested. Two of the four are built here from source
  # (mruby-lsp, value_bridge); the other two (prism, language_server-protocol)
  # are copied from THIS machine's gem cache (Gem::Specification#cache_file) --
  # whatever resolved versions are installed and working locally, never fetched.
  #
  # MTIMES MATTER. The mruby-lsp gem carries share/mtimes.json (recorded by
  # gem:mtimes inside gem:build) so that mruby-lsp-setup can restore stamps and
  # keep a byte-identical reinstall a no-op for mruby's mtime-driven rebuild.
  #
  # VERSIONING. Every package bumps BOTH gems we author (mruby-lsp + value_bridge)
  # so a marketplace update is recognized AND so the same-version reinstall no-op
  # (gem install of an already-installed version does nothing) can never leave a
  # stale value_bridge behind. value_bridge is pinned IN LOCKSTEP to mruby-lsp's
  # version -- they ship as one unit, so one version to reason about, no drift.
  # The external deps (prism, language_server-protocol) keep their upstream
  # versions untouched -- we don't author them, we just carry the .gem we tested.
  desc "Vendor the server gem + all runtime deps into the extension (.gem files)"
  task vendor_gems: "gem:build" do
    require "fileutils"
    require "json"
    require "rubygems"
    require "digest"

    vendor = File.join(VSCODE_DIR, "vendor", "gems")
    FileUtils.mkdir_p(vendor)

    # gem:build already bumped mruby-lsp and built it (with correct internal
    # mtimes); read the resulting version.
    version = `#{RbConfig.ruby} -r./lib/mruby_lsp/version -e "print MrubyLsp::VERSION"`.strip

    # Copy SRC to vendor/<basename>; preserve src mtime. (Always a fresh build for
    # our two authored gems since the version bumped; copy verbatim.)
    manifest = {}
    keep = []

    # 1. value_bridge: pin its version to mruby-lsp's (rewrite version.rb); the
    #    .gem itself is built into the stage by vscode:package. Lockstep bump
    #    guarantees a NEW version every package -> the extension's offline
    #    `gem install --local` always takes (no same-version no-op).
    vb_dir = File.join(__dir__, "vendor", "value_bridge")
    vb_version_rb = File.join(vb_dir, "lib", "value_bridge", "version.rb")
    File.write(vb_version_rb, <<~RUBY)
      # frozen_string_literal: true

      module ValueBridge
        VERSION = "#{version}"
      end
    RUBY
    manifest["value_bridge"] = version

    # 2. our own gems (mruby-lsp, value_bridge) are NOT placed in the repo tree;
    #    vscode:package builds them straight into the .vsix stage. Record versions.
    manifest["mruby-lsp"] = version

    # 3. External runtime deps (prism, rbs, language_server-protocol): fetch each
    #    one's portable source .gem straight from rubygems into the .vsix. No
    #    prior `gem install` on the build machine -- we do not want to depend on
    #    the dev having them installed, and a system install often prunes its
    #    cached .gem anyway. --platform ruby pulls the SOURCE gem, not a
    #    precompiled OS/arch build, so the .vsix stays cross-platform; the
    #    extension compiles native exts (prism, rbs) at install time, which is
    #    fine since mruby-lsp needs a C toolchain regardless. Content-stable:
    #    rubygems serves the same immutable bytes for a given version, so
    #    re-fetching an unchanged version leaves the vendored .gem (and its mtime)
    #    untouched -> the .vsix stays reproducible across OUR-gem-only bumps.
    require "tmpdir"
    require "rubygems/package"

    gem_exe = File.join(RbConfig::CONFIG["bindir"], "gem#{RbConfig::CONFIG["EXEEXT"]}")
    gem_exe = "gem" unless File.exist?(gem_exe)

    spec = Gem::Specification.load(File.join(__dir__, "mruby-lsp.gemspec"))

    # Vendor the FULL runtime-dependency CLOSURE, not just the direct deps.
    # `gem fetch <name>` pulls only the named gem — never its transitive deps —
    # so a direct-deps-only vendor ships rbs but leaves rbs's own `logger` and
    # `abbrev` out. A bundle-only GEM_PATH can't fall back to a default gem for
    # them either (logger stopped being a default gem in Ruby 4.0), so the
    # server's binstub dies activating rbs: "Could not find 'logger'". Walk the
    # graph breadth-first: fetch a gem, read its .gem spec's own runtime deps,
    # enqueue any unseen. Our two authored gems are built into the stage (not
    # fetched); skip them wherever they appear.
    ours  = %w[mruby-lsp value_bridge]
    seen  = {}
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
        abort "vendor_gems: `gem fetch #{name} -v '#{req}'` failed " \
              "(no network, or wrong name/version?)" unless ok

        fetched = Dir.glob(File.join(sub, "*.gem")).max_by { |f| File.mtime(f) }
        abort "vendor_gems: gem fetch produced no source .gem for #{name}" unless fetched

        dep_spec = Gem::Package.new(fetched).spec
        fname = File.basename(fetched)
        dst   = File.join(vendor, fname)
        same  = File.exist?(dst) && Digest::SHA256.file(dst) == Digest::SHA256.file(fetched)
        FileUtils.cp(fetched, dst, preserve: true) unless same
        keep << fname
        manifest[name] = dep_spec.version.to_s

        # Enqueue this gem's own runtime deps — the next layer of the closure.
        dep_spec.runtime_dependencies.each do |d|
          queue << [d.name, d.requirement.as_list.join(", ")] \
            unless seen[d.name] || ours.include?(d.name)
        end
      end
    end

    # Prune stale .gem files from previous versions so the vendor dir holds
    # exactly the current set (no orphaned old versions bloating the .vsix).
    Dir.glob(File.join(vendor, "*.gem")).each do |f|
      File.delete(f) unless keep.include?(File.basename(f))
    end

    # Embed the native fingerprint of THIS release: the hash of every C source
    # that feeds the cached build, computed by the SAME shared helper setup uses.
    # The extension compares this against each workspace's recorded `native` to
    # decide, WITHOUT running setup, which workspaces a native change has made
    # stale -- correct even when a user skips releases (it's hash-vs-hash, no
    # versions involved).
    require_relative "lib/mruby_lsp/native_fingerprint"
    manifest["native"] = MrubyLsp::NativeFingerprint.digest(__dir__)

    File.write(File.join(vendor, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
    puts "vendored #{manifest.size} gems into #{vendor}:"
    manifest.each { |n, v| puts "    #{n} #{v}" }
  end

  task package: %i[vendor_gems] do
    require "json"

    version = JSON.parse(File.read(File.join(VSCODE_DIR, "package.json")))["version"]
    final_vsix = File.join(VSCODE_DIR, "mruby-lsp-#{version}.vsix")

    # PERSISTENT stage (was a fresh tmpdir): a from-scratch npm install on
    # every packaging run re-resolved latest-everything from the registry --
    # minutes of hang plus a wall of transitive deprecation warnings from the
    # vsce toolchain. The stage lives in the XDG cache; node_modules survives
    # across runs and npm only runs at all when package-lock.json changed.
    xdg = ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache")
    stage = File.join(xdg, "mruby-lsp", "vsix-stage")
    FileUtils.mkdir_p(stage)

    # rsync the SOURCE into the stage preserving mtimes (-a => --times).
    # node_modules is excluded from transfer AND (being excluded) from
    # --delete, so the cached install survives. Every staged file keeps its
    # REAL on-disk mtime, not the copy time.
    sh "rsync", "-a", "--delete",
       "--exclude=node_modules", "--exclude=out", "--exclude=*.vsix",
       "--exclude=.vscode-test", "--exclude=.installed-lock",
       "#{VSCODE_DIR}/", "#{stage}/"

    # The repo LICENSE is the single source; vsce packs only what's in the
    # stage and prompts interactively (and warns) without one.
    FileUtils.cp(File.join(__dir__, "LICENSE"), File.join(stage, "LICENSE"))

    # Our own gems build their .gem straight into the stage's vendor/gems --
    # never into the repo tree. prism/language_server-protocol and manifest.json
    # rode in via the rsync above; value_bridge's version was pinned in
    # vendor_gems. mtimes stay correct: the on-disk source stamps are exactly
    # what gem:mtimes recorded, so the build packs them unchanged.
    gemsdir = File.join(stage, "vendor", "gems")
    FileUtils.mkdir_p(gemsdir)
    Dir.chdir(__dir__) do
      sh "gem build mruby-lsp.gemspec --output #{File.join(gemsdir, "mruby-lsp-#{version}.gem")}"
    end
    Dir.chdir(File.join(__dir__, "vendor", "value_bridge")) do
      sh "gem build value_bridge.gemspec --output #{File.join(gemsdir, "value_bridge-#{version}.gem")}"
    end

    Dir.chdir(stage) do
      # Deterministic, lock-driven, quiet. Skipped entirely when the lock that
      # built the cached node_modules is byte-identical to the current one.
      marker = ".installed-lock"
      lock = "package-lock.json"
      if !File.directory?("node_modules") || !File.exist?(marker) || !FileUtils.identical?(lock, marker)
        sh "npm install --no-audit --no-fund --loglevel=error"
        FileUtils.cp(lock, marker)
      else
        puts "    deps up to date, skipping npm install"
      end
      # Compile in-stage (out/extension.js is generated -> its mtime is build
      # time, which is correct; it is a fresh artifact, not a preserved source).
      sh "npm run compile"
      # vsce preserves the mtimes of what it packs; the stage already carries
      # the real source mtimes, so they pass through into the vsix unchanged.
      sh "#{stage_vsce(stage)} package --no-git-tag-version --allow-missing-repository --out mruby-lsp-#{version}.vsix"
    end

    # rsync the result OUT, preserving its mtime.
    sh "rsync", "-a", "#{stage}/mruby-lsp-#{version}.vsix", final_vsix

    puts "packaged #{final_vsix}"
  end

  desc "Verify the packaged .vsix has the pieces that silently break activation"
  task verify: :package do
    require "json"
    vsix = vsix_path
    list = `cd #{VSCODE_DIR} && unzip -l #{vsix}`

    checks = {
      "out/extension.js present"      => list.include?("extension/out/extension.js"),
      "vscode-languageclient bundled" => list.include?("vscode-languageclient/node.js"),
    }
    manifest = JSON.parse(`cd #{VSCODE_DIR} && unzip -p #{vsix} extension/package.json`)
    declared = manifest["contributes"]["commands"].map { |c| c["command"] }.sort
    js = `cd #{VSCODE_DIR} && unzip -p #{vsix} extension/out/extension.js`.force_encoding("UTF-8")
    registered = js.scan(/registerCommand\("([^"]+)"/).flatten.sort
    checks["declared commands == registered"] = (declared == registered)

    checks.each { |name, ok| puts "  #{ok ? 'ok ' : 'FAIL'}  #{name}" }
    failed = checks.reject { |_, ok| ok }
    abort "vsix verification failed: #{failed.keys.join(', ')}" unless failed.empty?
    puts "vsix verified"
  end

  desc "Build, package, and install the extension into VS Code (clean reinstall, bumps version)"
  task :install do
    abort "VS Code CLI 'code' not found on PATH" unless system("command -v code > /dev/null 2>&1")

    require "json"
    pkg = JSON.parse(File.read(File.join(VSCODE_DIR, "package.json")))
    # VS Code lowercases the publisher in the extension ID.
    ext_id = "#{pkg['publisher'].downcase}.#{pkg['name']}"

    # Uninstall any existing copy FIRST. VS Code can otherwise keep a stale
    # extension dir while registering the new version's metadata, so you end up
    # running old code under a new version number (this exact trap cost us a
    # whole debugging session). A clean uninstall guarantees the next install is
    # what actually loads.
    sh "#{editor_cli} --uninstall-extension #{ext_id} || true"

    Rake::Task["vscode:package"].invoke # package depends on bump
    vsix = vsix_path
    abort "vsix not found: #{vsix}" unless File.exist?(vsix)
    sh "#{editor_cli} --install-extension #{vsix} --force"

    version = JSON.parse(File.read(File.join(VSCODE_DIR, "package.json")))["version"]
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
