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
#     then execve Ruby on the gem's CLI dispatcher (lib/mruby_lsp/cli.rb) with the
#     command's role (server/setup/update). On non-Linux hosts the sandbox
#     primitives don't exist, so we ship a shell pass-through that runs the same
#     `ruby … mruby_lsp/cli` directly.
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
# executables. We ASK RubyGems instead of computing it — a prior version did
# `expand_path("../../../../bin", __dir__)` and wrote to `Gem.dir/bin`, a dir
# nobody knows: not on PATH, untracked, leaked on uninstall. `__dir__` math is
# doubly unsafe (it shifts with the extension nesting AND with gems/ vs
# extensions/ build dirs). `Gem.bindir` is already correct for two of the three
# install modes, and BOTH must keep working (`rake install` and the VS Code
# extension's bundled install — keep parity):
#   - root `gem install`           -> Gem.bindir = the Ruby exe dir.
#   - `gem install --install-dir D` -> Gem.bindir = D/bin. This is how the VS Code
#     extension installs the bundled server, and it is user-AGNOSTIC.
# The one mode it gets wrong is `--user-install` (non-root `rake install`): RubyGems
# keeps Gem.bindir/Gem.dir on the SYSTEM paths even though the gem lands in
# Gem.user_dir, so a bare Gem.bindir would orphan the launcher in the system bindir.
# So: follow Gem.bindir whenever a custom install dir is active (detected as
# `Gem.bindir != Gem.bindir(Gem.default_dir)` — covers --install-dir / GEM_HOME)
# OR we are root; only a plain non-root install falls back to the user gem home's
# bin. RubyGems APIs only — verified installing a probe gem in all three modes,
# as root AND as a real non-root user.
custom_install_dir = Gem.bindir != Gem.bindir(Gem.default_dir)
target_bindir = (custom_install_dir || Process.uid.zero?) ? Gem.bindir : Gem.bindir(Gem.user_dir)
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
# Compiled alongside the launcher on Linux; the setup role (lib/mruby_lsp/setup.rb)
# wraps the OFFLINE build phase with it so fetched code can't reach the network
# while it runs. Linux-only and degrade-safe: if it's not on disk, setup runs the
# build unwrapped (the fetch/build FS split still stands).
nonet_src = File.expand_path(File.join(gem_root, "ext", "mruby_lsp_launcher", "nonet.c"))
FileUtils.mkdir_p(target_bindir)
ext = RbConfig::CONFIG["EXEEXT"] # "" on Unix, ".exe" on Windows

# The launcher is installed under EACH user-facing name; ONE binary dispatches by
# its own basename (from /proc/self/exe) to the matching ROLE + confinement
# profile, then execve's Ruby on the gem's CLI dispatcher. There is no separate
# binstub (spec.executables is empty); the dispatcher ships in the gem's lib/.
launcher_names = %w[mruby-lsp mruby-lsp-setup mruby-lsp-update]
target_path = File.join(target_bindir, "mruby-lsp#{ext}")
# name -> the ROLE string handed to MrubyLsp::CLI.run (mirrors the C ROLES table).
role_for = {
  "mruby-lsp"        => "server",
  "mruby-lsp-setup"  => "setup",
  "mruby-lsp-update" => "update",
}

# Baked into the launcher at compile time (absolute, recorded from THIS install —
# like /proc/self/exe, not redirectable by env/argv): the Ruby that installed us,
# and the gem's lib/ dir holding the CLI dispatcher. The launcher execve's
# `<ruby> -I<lib_dir> -r mruby_lsp/cli -e '…' -- <role>`.
ruby_path = RbConfig.ruby
lib_dir   = File.join(gem_root, "lib")
defines   = ["-DMRUBY_LSP_RUBY=\"#{ruby_path}\"", "-DMRUBY_LSP_LIB=\"#{lib_dir}\""]

# The launcher is LINUX-ONLY by design: Landlock + seccomp + PR_SET_NO_NEW_PRIVS
# are Linux syscalls. macOS / Windows sandboxing is a different mechanism applied
# at process creation — see docs/design/SANDBOX-CROSSPLATFORM.md. So we only
# compile on Linux; elsewhere a shell pass-through execs Ruby on the script
# directly (unconfined — the server then asks the user, as on a Linux box without
# Landlock). mkmf has no `create_executable`, so we drive RbConfig's CC ourselves.

linux = RbConfig::CONFIG["host_os"] =~ /linux/i

# Try a STATIC link first: a static launcher has no dynamic loader, so no
# LD_PRELOAD/LD_AUDIT can inject into it before it confines. -static-pie keeps
# ASLR; fall back to -static, then a plain dynamic link (env-scrub still strips
# LD_*). getpwuid pulls NSS, which warns under static glibc but works for local
# accounts; an account it can't resolve simply degrades the home allow-list.
def compile_launcher(cc, out, src, defines)
  [["-static-pie"], ["-static"], []].each do |link|
    return :ok if system(cc, "-O2", "-Wall", "-Wextra", *link, *defines, "-o", out, src,
                         out: File::NULL, err: File::NULL)
  end
  # Last attempt, errors visible, so a genuine compile failure is diagnosable.
  system(cc, "-O2", "-Wall", "-Wextra", *defines, "-o", out, src) ? :ok : :fail
end

if linux && File.exist?(launcher_src)
  cc = RbConfig::CONFIG["CC"]
  cc = ENV["CC"] if ENV["CC"] && !ENV["CC"].empty?
  unless system(cc, "--version", out: File::NULL, err: File::NULL)
    abort "mruby-lsp: cannot find a C compiler (RbConfig CC=#{cc.inspect}). " \
          "The Linux sandbox launcher is mandatory; install gcc or clang " \
          "(or set CC) and reinstall."
  end
  if compile_launcher(cc, target_path, launcher_src, defines) != :ok
    abort "mruby-lsp: launcher build failed (CC=#{cc.inspect}). The Linux " \
          "sandbox launcher is mandatory; fix the compile error and reinstall."
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
  # build phase can be sealed. Build failure here is NOT fatal — the net seal is
  # defence-in-depth on top of the FS split, so we warn and continue.
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
  # Non-Linux (or missing source): a shell pass-through per name that runs Ruby on
  # the gem's CLI dispatcher with this command's role — no sandbox primitives here,
  # so it runs unconfined and the server asks the user via the LSP dialog. Works on
  # any host whose shell understands `#!/bin/sh` (macOS, *BSD). True Windows support
  # is separate work; see docs/design/SANDBOX-CROSSPLATFORM.md.
  launcher_names.each do |name|
    dst = File.join(target_bindir, "#{name}#{ext}")
    File.write(dst, <<~SH)
      #!/bin/sh
      # #{name} pass-through (no Linux sandbox primitives on this host; unconfined).
      exec "#{ruby_path}" -I "#{lib_dir}" -r mruby_lsp/cli -e 'MrubyLsp::CLI.run(ARGV.shift, ARGV)' -- #{role_for[name]} "$@"
    SH
    File.chmod(0o755, dst)
  end
end

# No-op Makefile that satisfies RubyGems' contract on any Make implementation
# (GNU make, BSD make, nmake). Single empty rule declared for all three targets
# RubyGems invokes. The actual install above already finished.
File.write("Makefile", "all install clean:\n")
