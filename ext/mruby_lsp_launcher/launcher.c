/*
 * mruby-lsp — Linux re-exec prelude (the "born-confined" launcher).
 *
 * ONE binary, installed under each user-facing name (`mruby-lsp`,
 * `mruby-lsp-setup`, `mruby-lsp-update`). It picks its role from its OWN
 * basename (/proc/self/exe) — see ROLES[] below — and execve()s Ruby on this
 * gem's CLI dispatcher (lib/mruby_lsp/cli.rb), passing the role as a fixed
 * argument: `ruby -I<lib> -r mruby_lsp/cli -e 'MrubyLsp::CLI.run(ARGV.shift,
 * ARGV)' -- <role> …`. There is no per-command binstub. Confinement is
 * MANDATORY: the launcher always attempts every step its role calls for, then
 * execs Ruby. The FS wall is role-gated (server: on; build/fetch: deferred —
 * see ROLES[] and SANDBOX-CROSSPLATFORM.md).
 *
 * SECURITY INVARIANT — the environment steers NOTHING here.
 *   This binary is the confinement boundary, and env is precisely what an
 *   untrusted parent controls (a poisoned editor environment, a malicious
 *   workspace's build tooling that the editor inherits). So no env var may
 *   widen the Landlock allow-list, redirect the exec target, or toggle a step.
 *   Every path comes from the kernel — getpwuid(getuid()) for the home,
 *   /proc/self/exe for our own location — or from compile-time constants. The
 *   only environment we touch is the kill-list we SCRUB (LD_PRELOAD &c.), and
 *   that is removal, never control.
 *
 * Steps:
 *   1. fd hygiene  — close everything >2.
 *   2. env scrub   — drop LD_PRELOAD / LD_AUDIT / LD_LIBRARY_PATH so no shim
 *                    loads into the post-exec image.
 *   3. PR_SET_NO_NEW_PRIVS — precondition for unprivileged seccomp; also good
 *                    hygiene under Landlock.
 *   4. Landlock    — STAGE 1 of two: confine WRITES + EXEC, but NOT reads. The
 *                    workspace isn't known yet (its only spec-portable source is
 *                    the LSP `initialize`, which arrives after exec) and Landlock
 *                    only tightens, so reads must stay open here; the SERVER
 *                    raises the stage-2 READ wall after initialize (the
 *                    MrubyLsp::Landlock ext, ext/mruby_lsp_landlock). On ENOSYS /
 *                    unsupported ABI / build headers too old, DEGRADE GRACEFULLY.
 *   5. seccomp     — an allow-all filter as a MARKER (not a restriction), set
 *                    only after stage-1 Landlock succeeds, so /proc/self/status
 *                    `Seccomp:` is the truthful "confined" signal the server reads
 *                    (Landlock itself is not introspectable). Children inherit it;
 *                    the real net seal stays in mruby-lsp-nonet (build phase).
 *   6. execve      — Ruby on this gem's CLI dispatcher (baked lib dir), handing
 *                    it this role's name. No binstub, no PATH search.
 *
 * Build with -DMRUBY_LSP_SANDBOX_VERBOSE for stderr debug logging. That is a
 * COMPILE-TIME switch, not an env var, and it never disables any step.
 *
 * This binary is small and dumb on purpose: it resolves paths, makes syscalls,
 * and execve()s. No parsing of project input.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <pwd.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>

/* Landlock support is decided entirely at BUILD time by what the kernel headers
 * provide. We never hardcode syscall numbers: __NR_landlock_* is architecture-
 * specific — the same integer is an unrelated syscall on i386/mips/powerpc/
 * s390/arm — so a guessed fallback would invoke the WRONG syscall with Landlock
 * arguments (pointers reinterpreted as flags, &c.), which is far worse than no
 * Landlock at all. If the headers predate Landlock (< 5.13) or simply don't
 * name the syscalls, we compile the step out and degrade, the same graceful
 * path as a runtime kernel that lacks it. */
#if defined(__has_include)
# if __has_include(<linux/landlock.h>)
#  include <linux/landlock.h>
#  define MRUBY_LSP_LANDLOCK_HDR 1
# endif
#endif

#if defined(MRUBY_LSP_LANDLOCK_HDR) && \
    defined(__NR_landlock_create_ruleset) && \
    defined(__NR_landlock_add_rule) && \
    defined(__NR_landlock_restrict_self)
# define MRUBY_LSP_HAVE_LANDLOCK 1
# ifndef LANDLOCK_CREATE_RULESET_VERSION
#  define LANDLOCK_CREATE_RULESET_VERSION (1U << 0)
# endif
#else
# define MRUBY_LSP_HAVE_LANDLOCK 0
#endif

/* seccomp: used here ONLY as the "I am confined" MARKER. The launcher applies a
 * permissive (allow-all) filter as the FINAL confinement step, reached only after
 * Landlock succeeded; the server then reads /proc/self/status `Seccomp:` to learn
 * env- and arg-free whether it is confined (Landlock itself is not introspectable).
 * Why ALLOW-ALL and not a real restriction: the server spawns the updater/setup
 * (`rake fetch`, needs the network) as a CHILD, which INHERITS this filter — a
 * network-deny here would break the fetch. The dedicated network seal stays where
 * it belongs: mruby-lsp-nonet around the offline BUILD phase (stacked on top). */
#if defined(__has_include)
# if __has_include(<linux/seccomp.h>) && __has_include(<linux/filter.h>)
#  include <linux/seccomp.h>
#  include <linux/filter.h>
#  define MRUBY_LSP_HAVE_SECCOMP 1
# endif
#endif

/* ── logging (compile-time only; never env-driven) ───────────────────────── */
#ifdef MRUBY_LSP_SANDBOX_VERBOSE
static void vlog(const char *fmt, ...)
{
    va_list ap;
    fprintf(stderr, "[mruby-lsp-sandbox] ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}
#else
static inline void vlog(const char *fmt, ...) { (void)fmt; }
#endif

/* ── 1. fd hygiene ───────────────────────────────────────────────────────── */
static void close_stray_fds(void)
{
    /* Prefer the /proc/self/fd walk; fall back to a bounded loop. */
    DIR *d = opendir("/proc/self/fd");
    if (d) {
        int dirfd_ = dirfd(d);
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (!isdigit((unsigned char)e->d_name[0])) continue;
            int fd = atoi(e->d_name);
            if (fd <= 2 || fd == dirfd_) continue;
            close(fd);
        }
        closedir(d);
        return;
    }
    /* Fallback: try a generous range. */
    for (int fd = 3; fd < 4096; fd++) close(fd);
}

/* ── 2. env scrub ─────────────────────────────────────────────────────────── */
static void scrub_env(void)
{
    /* Removal, not control: drop loader-injection vectors so no shim loads into
     * the post-exec image. unsetenv is a no-op when the var is absent. */
    static const char *kill_list[] = {
        "LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
        /* macOS analogues are no-ops on Linux but harmless to scrub: */
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        NULL
    };
    for (const char **k = kill_list; *k; k++) {
        vlog("scrub env: %s", *k);
        unsetenv(*k);
    }
}

/* ── 3. seccomp MARKER (allow-all; the confinement signal, not a restriction) ─ */
/* Returns 0 if a filter was installed (Seccomp: 2 becomes visible in
 * /proc/self/status), -1 otherwise. Requires NO_NEW_PRIVS (set by main first).
 * Deliberately allow-all: see the header note — children need the network. */
static int apply_seccomp_marker(void)
{
#if MRUBY_LSP_HAVE_SECCOMP
    struct sock_filter f[] = { BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW) };
    struct sock_fprog prog = { .len = 1, .filter = f };
    if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog) == 0) return 0;
    /* Fallback for kernels/libcs without the seccomp() wrapper path. */
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0) == 0) return 0;
    vlog("seccomp marker failed: %s", strerror(errno));
    return -1;
#else
    return -1;
#endif
}

/* ── role dispatch ────────────────────────────────────────────────────────── */
/* One launcher binary, installed under each user-facing name. WHICH executable
 * we are is decided by our OWN real basename (from /proc/self/exe — kernel
 * truth, not the spoofable argv[0], not env). The name selects the role string
 * we hand the CLI dispatcher and whether the Landlock FS wall applies. */
struct role {
    const char *name;    /* our installed basename */
    const char *target;  /* role string passed to MrubyLsp::CLI.run (server/…) */
    int         fs_wall; /* 1: install the Landlock FS allow-list. 0: process
                          * hardening only — the build/fetch FS footprint is not
                          * yet walled (mruby_root can live outside the
                          * workspace; a too-tight wall would fail the build,
                          * and a failed build is the one forbidden outcome).
                          * See docs/design/SANDBOX-CROSSPLATFORM.md. */
};
static const struct role ROLES[] = {
    { "mruby-lsp",        "server", 1 },
    { "mruby-lsp-setup",  "setup",  0 },
    { "mruby-lsp-update", "update", 0 },
};

static const struct role *current_role(void)
{
    char exe[4096];
    ssize_t r = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (r <= 0) return NULL;
    exe[r] = '\0';
    const char *base = strrchr(exe, '/');
    base = base ? base + 1 : exe;
    for (size_t i = 0; i < sizeof ROLES / sizeof ROLES[0]; i++)
        if (strcmp(base, ROLES[i].name) == 0) return &ROLES[i];
    return NULL;
}

/* ── target resolution: Ruby + the gem's lib dir, baked in at install ───────── */
/* The Ruby interpreter and the gem's lib/ directory are compiled into THIS binary
 * by the install hook (ext/mruby_lsp_install/extconf.rb), recorded from the exact
 * gem being installed. Both are absolute and — like /proc/self/exe — cannot be
 * redirected by env or argv. We execve Ruby on the CLI dispatcher
 * (`<lib>/mruby_lsp/cli.rb`, reached via `-I<lib> -r mruby_lsp/cli`): no binstub,
 * no PATH search. lib/ sits under self_gemhome (dirname^2 of our own
 * path) and so under the Landlock RX rule. Missing/empty defines (a dev build that
 * forgot to bake them) -> fail loud in main(). */
#ifndef MRUBY_LSP_RUBY
# define MRUBY_LSP_RUBY ""
#endif
#ifndef MRUBY_LSP_LIB
# define MRUBY_LSP_LIB ""
#endif

#if MRUBY_LSP_HAVE_LANDLOCK
/* ── 4. Landlock ──────────────────────────────────────────────────────────── */
/* Add a path rule. Missing/unreadable paths are skipped silently — they would
 * just contribute no rule. */
static int add_path_rule(int ruleset_fd, const char *path, uint64_t allowed)
{
    int pfd = open(path, O_PATH | O_CLOEXEC);
    if (pfd < 0) {
        vlog("landlock: skip %s (open: %s)", path, strerror(errno));
        return 0; /* missing path is not an error */
    }
    struct landlock_path_beneath_attr pb = {
        .allowed_access = allowed,
        .parent_fd = pfd,
    };
    long r = syscall(__NR_landlock_add_rule, ruleset_fd,
                     LANDLOCK_RULE_PATH_BENEATH, &pb, 0);
    close(pfd);
    if (r) {
        vlog("landlock: add_rule(%s) failed: %s", path, strerror(errno));
        return -1;
    }
    return 0;
}

/* Two `dirname` of an absolute path, in place. For
 * "/path/to/gemhome/bin/binstub" -> "/path/to/gemhome". The launcher and the
 * Ruby binstubs live in <gemhome>/bin/, the gem sources in <gemhome>/gems/,
 * specifications in <gemhome>/specifications/, extensions in <gemhome>/
 * extensions/. Adding <gemhome> to the Landlock RX allow list means execve
 * of the binstub AND every Ruby require from the gem set go through. */
static void dirname_twice(char *buf)
{
    for (int i = 0; i < 2; i++) {
        char *slash = strrchr(buf, '/');
        if (!slash) { buf[0] = '\0'; return; }
        if (slash == buf) { buf[1] = '\0'; return; }   /* keep root "/" */
        *slash = '\0';
    }
}

/* The gem-install root = dirname^2 of our REAL path (/proc/self/exe). Never from
 * argv[0] (spoofable) and never from env. */
static int self_gemhome(char *out, size_t n)
{
    ssize_t r = readlink("/proc/self/exe", out, n - 1);
    if (r <= 0) return -1;
    out[r] = '\0';
    dirname_twice(out);
    return out[0] ? 0 : -1;
}

/* The invoking user's home from the passwd database, NOT $HOME. $HOME is
 * attacker-settable and would relocate the writable cache root inside the
 * sandbox; getpwuid(getuid()) reads the system account record instead. */
static const char *real_home(void)
{
    struct passwd *pw = getpwuid(getuid());
    return (pw && pw->pw_dir && pw->pw_dir[0]) ? pw->pw_dir : NULL;
}

static int apply_landlock(void)
{
    /* Query ABI; degrade gracefully on ENOSYS (kernel without Landlock) or
     * EOPNOTSUPP (Landlock disabled). */
    long abi = syscall(__NR_landlock_create_ruleset, NULL, 0,
                       LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 0) {
        vlog("landlock: ABI query failed: %s (errno %d) — degrading",
             strerror(errno), errno);
        return -1;
    }
    vlog("landlock: ABI=%ld", abi);

    /* STAGE 1 (pre-Ruby): confine WRITES + EXEC only — deliberately NOT reads.
     * The workspace isn't known here: the only spec-portable source is the LSP
     * `initialize` request, which arrives AFTER we exec Ruby. And Landlock layers
     * can only tighten, so a read rule set now could never be widened to include
     * the workspace later. So reads stay OPEN in stage 1; the SERVER stacks the
     * read wall in stage 2 once it has the rootUri (MrubyLsp::Landlock, built
     * from ext/mruby_lsp_landlock). The pre-stage-2 window runs only trusted code
     * (our gem + prism/rdoc); reflect.so is loaded only after stage 2 is up. */
    uint64_t write_set =
        LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR |
        LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG |
        LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO |
        LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM;
#ifdef LANDLOCK_ACCESS_FS_REFER
    if (abi >= 2) write_set |= LANDLOCK_ACCESS_FS_REFER;
#endif
#ifdef LANDLOCK_ACCESS_FS_TRUNCATE
    if (abi >= 3) write_set |= LANDLOCK_ACCESS_FS_TRUNCATE;
#endif
    uint64_t handled = write_set | LANDLOCK_ACCESS_FS_EXECUTE;

    uint64_t x  = LANDLOCK_ACCESS_FS_EXECUTE;             /* exec-only dirs        */
    uint64_t w  = write_set;                              /* write-only sinks      */
    uint64_t wx = write_set | LANDLOCK_ACCESS_FS_EXECUTE; /* build dirs: mkmf execs
                                                           * its conftest binaries */

    struct landlock_ruleset_attr ra = { .handled_access_fs = handled };
    int ruleset_fd = syscall(__NR_landlock_create_ruleset, &ra, sizeof(ra), 0);
    if (ruleset_fd < 0) {
        vlog("landlock: create_ruleset failed: %s — degrading", strerror(errno));
        return -1;
    }

    /* EXEC: the interpreter we're about to execve, the C toolchain (the server
     * may spawn the setup build), and version-manager shims. Their READS are
     * already open in stage 1, so no read grant is needed. */
    add_path_rule(ruleset_fd, "/usr",  x);
    add_path_rule(ruleset_fd, "/bin",  x);
    add_path_rule(ruleset_fd, "/sbin", x);
    add_path_rule(ruleset_fd, "/opt",  x);

    /* WRITE sinks. Tempdirs are write+exec (mkmf/gcc compile and RUN conftest
     * binaries there); the safe /dev nodes are write-only (RubyGems writes
     * File::NULL on startup); everything else can't be written. */
    add_path_rule(ruleset_fd, "/tmp",     wx);
    add_path_rule(ruleset_fd, "/var/tmp", wx);
    add_path_rule(ruleset_fd, "/dev/null", LANDLOCK_ACCESS_FS_WRITE_FILE);
    add_path_rule(ruleset_fd, "/dev/tty",  LANDLOCK_ACCESS_FS_WRITE_FILE);

    /* OUR cache/state under the passwd home — the only place we ever write. We
     * do NOT read $XDG_CACHE_HOME / $XDG_DATA_HOME / $HOME (env, attacker-
     * settable); the server side matches this FIXED layout. The cache holds the
     * build (compiles + conftest execs) -> write+exec; the data dir holds
     * install.json + setup state -> write only. */
    const char *home = real_home();
    if (home) {
        char p[4096];
        snprintf(p, sizeof p, "%s/.cache/mruby-lsp", home);
        add_path_rule(ruleset_fd, p, wx);
        snprintf(p, sizeof p, "%s/.local/share/mruby-lsp", home);
        add_path_rule(ruleset_fd, p, w);
        /* Version managers drop shims/binstubs under the home — EXEC only: */
        snprintf(p, sizeof p, "%s/.rbenv", home); add_path_rule(ruleset_fd, p, x);
        snprintf(p, sizeof p, "%s/.rvm",   home); add_path_rule(ruleset_fd, p, x);
        snprintf(p, sizeof p, "%s/.asdf",  home); add_path_rule(ruleset_fd, p, x);
        snprintf(p, sizeof p, "%s/.gem",   home); add_path_rule(ruleset_fd, p, x);
        snprintf(p, sizeof p, "%s/.local/share/gem", home);
        add_path_rule(ruleset_fd, p, x);
    }

    /* The launcher's own gem-install root: EXEC (binstubs / native helpers). The
     * require chain (reads) is open in stage 1; stage 2 re-grants reads on this
     * root explicitly via Gem.path. Works for any layout (system, --user-install,
     * --install-dir <bundled>). */
    char gemhome[4096];
    if (self_gemhome(gemhome, sizeof gemhome) == 0) {
        add_path_rule(ruleset_fd, gemhome, x);
        vlog("landlock: stage-1 gem root X = %s", gemhome);
    }

    if (syscall(__NR_landlock_restrict_self, ruleset_fd, 0)) {
        vlog("landlock: restrict_self failed: %s — degrading", strerror(errno));
        close(ruleset_fd);
        return -1;
    }
    close(ruleset_fd);
    vlog("landlock: stage-1 (write/exec) active");
    return 0;
}
#else  /* !MRUBY_LSP_HAVE_LANDLOCK — kernel headers can't name the syscalls */
static int apply_landlock(void)
{
    vlog("landlock: not available at build time — degrading");
    return -1;
}
#endif

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(int argc, char **argv)
{
    /* Who are we? Our real basename selects the impl + the confinement profile. */
    const struct role *role = current_role();
    if (!role) {
        fprintf(stderr,
                "mruby-lsp: launcher invoked under an unrecognized name; it must "
                "be installed as one of mruby-lsp / mruby-lsp-setup / "
                "mruby-lsp-update.\n");
        return 127;
    }

    /* We do NOT take the workspace from argv. The only spec-portable source of
     * the workspace is the LSP `initialize` request (rootUri / workspaceFolders),
     * which the SERVER reads after we exec — see ext/mruby_lsp_landlock + the
     * stage-2 read wall in server.rb. The launcher's stage-1 wall (writes/exec) is
     * workspace-independent, so it needs nothing from argv. argv is still
     * forwarded verbatim to the server below (a client MAY pass a root as a hint),
     * but it never steers the security floor. */
    close_stray_fds();
    scrub_env();

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
        vlog("PR_SET_NO_NEW_PRIVS failed: %s", strerror(errno));

    if (role->fs_wall) {
        if (apply_landlock() == 0) {
            /* MARKER, last: only now — stage-1 Landlock up — do we set the seccomp
             * filter, so an active filter (visible in /proc/self/status) truthfully
             * means "stage-1 confined". The server reads that to decide, env/arg-
             * free, whether to raise the stage-2 read wall and run, or to ask the
             * user (see SandboxStatus). */
            apply_seccomp_marker();
        } else {
            /* Landlock could NOT be applied (old kernel, disabled, error). We do
             * NOT silently pretend: we leave the seccomp marker UNSET, so the
             * server sees Seccomp:0 and prompts the user (continue/abort) instead
             * of running unconfined behind the user's back. env-scrub + NNP still
             * applied above. */
            vlog("landlock: not active — %s will report itself UNCONFINED",
                 role->name);
        }
    } else {
        /* Build/fetch roles (setup/update): process hardening only. NO Landlock
         * (the build needs broad FS) and NO seccomp marker (they aren't the
         * confined server, and they spawn `rake fetch` which needs the network). */
        vlog("role %s: process hardening only (NNP + env-scrub)", role->name);
    }

    /* Exec Ruby on this gem's CLI dispatcher (baked Ruby + lib dir — no binstub,
     * no PATH). The role string comes from our ROLES table, not env/argv.
     * Landlock/seccomp/NNP are inherited across execve. */
    const char *ruby = MRUBY_LSP_RUBY;
    const char *lib  = MRUBY_LSP_LIB;
    if (ruby[0] == '\0' || lib[0] == '\0') {
        fprintf(stderr,
                "mruby-lsp: gem entry not baked (ruby=%s, lib=%s). The install "
                "hook bakes these in; reinstall the gem.\n",
                ruby[0] ? ruby : "(unbaked)", lib[0] ? lib : "(unbaked)");
        return 127;
    }

    /* new argv:
     *   ruby -I <lib> -r mruby_lsp/cli -e <bootstrap> -- <role> <our args...>
     * The 9-slot fixed prefix + (argc-1) forwarded args + NULL. */
    static const char *const BOOTSTRAP = "MrubyLsp::CLI.run(ARGV.shift, ARGV)";
    const int PREFIX = 9;
    char **new_argv = calloc((size_t)PREFIX + (size_t)argc, sizeof(char *));
    if (!new_argv) { perror("calloc"); return 1; }
    int n = 0;
    new_argv[n++] = (char *)ruby;
    new_argv[n++] = (char *)"-I";
    new_argv[n++] = (char *)lib;
    new_argv[n++] = (char *)"-r";
    new_argv[n++] = (char *)"mruby_lsp/cli";
    new_argv[n++] = (char *)"-e";
    new_argv[n++] = (char *)BOOTSTRAP;
    new_argv[n++] = (char *)"--";
    new_argv[n++] = (char *)role->target;          /* the role string */
    for (int i = 1; i < argc; i++) new_argv[n++] = argv[i];
    new_argv[n] = NULL;

    vlog("execve %s -I %s -r mruby_lsp/cli -e '%s' -- %s",
         ruby, lib, BOOTSTRAP, role->target);
    execv(ruby, new_argv);
    fprintf(stderr, "mruby-lsp: execv(%s): %s\n",
            ruby, strerror(errno));
    return 127;
}
