# frozen_string_literal: true

# Runs at gem-install time (declared as a gem "extension"). Two jobs:
#
#  1. Record WHERE this gem installed its executables, so the VS Code extension
#     can find `mruby-lsp` and `mruby-lsp-setup` without the user editing PATH.
#     Written to ~/.local/share/mruby-lsp/install.json, with the home resolved
#     ENV-FREE from the passwd database — NOT $XDG_DATA_HOME/$HOME.
#
#  2. Install `mruby-lsp` itself into the gem's bindir. On Linux this is the
#     COMPILED sandbox launcher (ext/mruby_lsp_launcher/launcher.c); its job is
#     to install Landlock + scrub LD_* + close stray fds + PR_SET_NO_NEW_PRIVS,
#     then execve into `mruby-lsp-server` (the Ruby server script). On non-Linux
#     hosts the sandbox primitives don't exist, so we ship a shell pass-through
#     that just execs `mruby-lsp-server`.
#
# Confinement is MANDATORY on Linux — there is no env var to disable it. The
# launcher's own internal contract is "degrade, don't crash": Landlock ENOSYS
# or a missing ABI bit means the FS wall is skipped; env-scrub / fd-hygiene /
# NoNewPrivs still apply and the server starts.
#
# ALL REAL WORK HAPPENS IN THIS RUBY SCRIPT. Two prior approaches both broke:
#  - Compiling via Make: the gem install path can contain SPACES ("Code - OSS"
#    on Linux VSCodium-OSS, "Application Support" on macOS, "Program Files" on
#    Windows). GNU make has no way to escape spaces in prerequisite lists, so
#    a rule like `$(OUT): $(SRC)` with a spaced SRC silently splits and aborts.
#  - Compiling here AND letting Make install: RubyGems always runs `make clean`
#    after extconf.rb, which deleted the binary before `make install` ran.
#  - And: msvc has no `make` at all (nmake's syntax differs from gmake).
# So: this script does the full build + install. The Makefile we write is a
# pure no-op — it only exists to satisfy RubyGems' "an extension must produce
# a Makefile" contract; `make clean / all / install` all do nothing.

require "fileutils"
require "json"
require "rbconfig"
require "etc"

# WHERE install.json lands is a FIXED path: the home comes from the passwd
# database (getpwuid), never $HOME/$XDG_DATA_HOME. This is the same env-free rule
# the build cache, the setup-state store, the C launcher (getpwuid), and the VS
# Code extension (os.userInfo) all follow — so every side agrees on the one
# directory and the environment can't relocate the record somewhere else.
home =
  begin
    Etc.getpwuid(Process.uid).dir
  rescue ArgumentError, SystemCallError
    Dir.home   # last resort only if the uid has no passwd entry
  end
data_dir = File.join(home, ".local", "share", "mruby-lsp")
FileUtils.mkdir_p(data_dir)

gem_root = File.expand_path(File.join(__dir__, "..", ".."))
require_relative File.join(gem_root, "lib", "mruby_lsp", "version")
version = MrubyLsp::VERSION

# The launcher goes in the SAME directory RubyGems uses for THIS install's
# executables, so it is on PATH and co-located with the impl binstubs (the
# /proc/self/exe sibling contract). We ask RubyGems for that directory instead of
# computing it — a PRIOR version did `expand_path("../../../../bin", __dir__)` and
# wrote to `Gem.dir/bin`, a directory nobody knows: not on PATH, untracked by
# RubyGems, so its binaries leaked on uninstall. `__dir__` math is doubly unsafe
# here: the result shifts with the extension's nesting depth AND with whether
# RubyGems builds under `gems/` or `extensions/`.
#
# The install command convention (see Rakefile / README): root installs into the
# system gem home, an unprivileged user installs with `--user-install`. RubyGems
# does NOT switch `Gem.bindir`/`Gem.dir` for `--user-install` — both keep pointing
# at the SYSTEM paths even though the gem lands in `Gem.user_dir` — so a bare
# `Gem.bindir` would orphan the launcher in the system bindir during a user
# install. Mirror the same root check the install command made (empirically
# verified by installing a probe gem both ways):
#   root      -> Gem.bindir                 (the Ruby exe dir, e.g. .../versions/X/bin)
#   non-root  -> Gem.bindir(Gem.user_dir)   (.../.local/share/gem/ruby/X/bin)
target_bindir = Process.uid.zero? ? Gem.bindir : Gem.bindir(Gem.user_dir)
# `bin_candidates` is read by the VS Code extension when it goes looking for the
# launcher; the recorded `bin` is the one truth.
candidates = [target_bindir]

File.write(
  File.join(data_dir, "install.json"),
  JSON.pretty_generate(
    "bin"            => target_bindir,
    "bin_candidates" => candidates,
    "version"        => version,
    "ruby"           => RbConfig.ruby,
  ) + "\n",
)

# ── Build + install `mruby-lsp` into the bindir ─────────────────────────────

launcher_src = File.expand_path(File.join(gem_root, "ext", "mruby_lsp_launcher", "launcher.c"))
# mruby-lsp-nonet: the offline-build wrapper (seccomp AF_INET/AF_INET6 deny).
# Compiled alongside the launcher on Linux; mruby-lsp-setup-impl wraps the
# OFFLINE build phase with it so fetched code can't reach the network while it
# runs. Linux-only and degrade-safe: if it's not on disk, setup runs the build
# unwrapped (the fetch/build FS split still stands).
nonet_src = File.expand_path(File.join(gem_root, "ext", "mruby_lsp_launcher", "nonet.c"))
FileUtils.mkdir_p(target_bindir)
ext = RbConfig::CONFIG["EXEEXT"] # "" on Unix, ".exe" on Windows

# The launcher is installed under EACH user-facing name; one binary, it
# dispatches by its own basename (from /proc/self/exe) to the matching impl
# sibling + confinement profile. The impl Ruby scripts are the RubyGems-
# installed `-server` / `-setup-impl` / `-update-impl` binstubs alongside.
launcher_names = %w[mruby-lsp mruby-lsp-setup mruby-lsp-update]
# RbConfig::CONFIG["EXEEXT"] is empty on Unix and ".exe" on Windows — the
# binstub name has to match what RubyGems would put in bindir for that host.
target_path = File.join(target_bindir, "mruby-lsp#{ext}")
# name -> impl the (non-Linux) pass-through must exec; mirrors the C ROLES table.
passthrough_target = {
  "mruby-lsp"        => "mruby-lsp-server",
  "mruby-lsp-setup"  => "mruby-lsp-setup-impl",
  "mruby-lsp-update" => "mruby-lsp-update-impl",
}

# The launcher is LINUX-ONLY by design: Landlock + seccomp + PR_SET_NO_NEW_PRIVS
# are Linux syscalls. macOS sandboxing is App Sandbox via a signed entitlement
# (different mechanism, different C, applied by the kernel at process creation);
# Windows is a restricted/AppContainer token + Job (set by the parent at
# CreateProcess) — see docs/design/SANDBOX-CROSSPLATFORM.md. So we only compile
# on Linux; everywhere else we ship a shell pass-through and `mruby-lsp` still
# resolves to a working command (the Ruby server runs unconfined).
#
# Why not use mkmf to do the build portably? mkmf's stdlib API is designed for
# building Ruby C extensions (shared libraries linked against libruby), not
# standalone executables — there is no `create_executable` analogous to
# `create_makefile`. We do use RbConfig::CONFIG["CC"], which IS mkmf's blessed
# compiler choice (RbConfig honors --with-cc / the build-time configure), and
# the -O2/-Wall/-Wextra flags are accepted by every Linux compiler Ruby reports
# (gcc, clang). On the platforms where these flags wouldn't apply — Windows
# (msvc /O2 /W4) — we don't compile at all.

linux = RbConfig::CONFIG["host_os"] =~ /linux/i

if linux && File.exist?(launcher_src)
  cc = RbConfig::CONFIG["CC"]
  cc = ENV["CC"] if ENV["CC"] && !ENV["CC"].empty?
  unless system(cc, "--version", out: File::NULL, err: File::NULL)
    abort "mruby-lsp: cannot find a C compiler (RbConfig CC=#{cc.inspect}). " \
          "The Linux sandbox launcher is mandatory; install gcc or clang " \
          "(or set CC) and reinstall."
  end
  unless system(cc, "-O2", "-Wall", "-Wextra", "-o", target_path, launcher_src)
    abort "mruby-lsp: launcher build failed (CC=#{cc.inspect} returned " \
          "non-zero). The Linux sandbox launcher is mandatory; fix the compile " \
          "error and reinstall."
  end
  File.chmod(0o755, target_path)
  # Same binary under each name — it picks its role from its own basename.
  (launcher_names - ["mruby-lsp"]).each do |name|
    dst = File.join(target_bindir, "#{name}#{ext}")
    FileUtils.cp(target_path, dst)
    File.chmod(0o755, dst)
  end

  # The offline-build wrapper. Separate tiny binary (not a launcher role): it
  # takes a command and execs it behind the no-network seccomp filter, so the
  # build phase can be sealed without touching the launcher's basename dispatch.
  # Build failure here is NOT fatal — the net seal is defence-in-depth on top of
  # the FS split, so we warn and continue (setup degrades to an unwrapped build).
  if File.exist?(nonet_src)
    nonet_path = File.join(target_bindir, "mruby-lsp-nonet#{ext}")
    if system(cc, "-O2", "-Wall", "-Wextra", "-o", nonet_path, nonet_src)
      File.chmod(0o755, nonet_path)
    else
      warn "mruby-lsp: mruby-lsp-nonet build failed (CC=#{cc.inspect}); the " \
           "offline-build network seal will be skipped (FS split still applies)."
    end
  end
else
  # Non-Linux (or missing source): ship a shell pass-through per name. No
  # sandboxing (primitives are Linux-specific), but each command remains a
  # working entry on hosts whose shell understands `#!/bin/sh` (macOS, *BSD).
  # True Windows support — a .cmd shim *plus* a token+Job/AppContainer launcher
  # in C — is separate work; see docs/design/SANDBOX-CROSSPLATFORM.md.
  launcher_names.each do |name|
    dst = File.join(target_bindir, "#{name}#{ext}")
    File.write(dst, <<~SH)
      #!/bin/sh
      # #{name} pass-through (no Linux sandbox primitives available on this host).
      exec #{passthrough_target[name]} "$@"
    SH
    File.chmod(0o755, dst)
  end
end

# The launcher resolves its impl (`-server` / `-setup-impl` / `-update-impl`) as
# a /proc/self/exe sibling — and those ARE the binstubs RubyGems itself installs
# into this same `target_bindir` (= the install's EXECUTABLE DIRECTORY). So we
# write NOTHING for them: the siblings already exist, correct and RubyGems-tracked.
# We deliberately do not drop our own wrappers at those names — they would collide
# with RubyGems' binstubs (`gem install` aborts: "<name> conflicts with …"), and
# overwriting them would orphan files RubyGems otherwise removes on uninstall.

# No-op Makefile that satisfies RubyGems' contract on any Make implementation
# (GNU make, BSD make, nmake). Single empty rule declared for all three targets
# RubyGems invokes. The actual install above already finished.
File.write("Makefile", "all install clean:\n")
