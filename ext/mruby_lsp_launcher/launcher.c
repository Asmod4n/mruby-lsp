/*
 * mruby-lsp — Linux re-exec prelude (the "born-confined" launcher).
 *
 * ONE binary, installed under each user-facing name (`mruby-lsp`,
 * `mruby-lsp-setup`, `mruby-lsp-update`). It picks its role from its OWN
 * basename (/proc/self/exe) — see ROLES[] below — and execve()s the matching
 * impl sibling. Confinement is MANDATORY: the launcher always attempts every
 * step its role calls for, then execs the impl. The FS wall is role-gated
 * (server: on; build/fetch: deferred — see ROLES[] and SANDBOX-CROSSPLATFORM.md).
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
 *   4. Landlock    — install an FS allow-list; on ENOSYS or any unsupported
 *                    ABI bit (or kernel headers too old to even name the
 *                    syscalls at build time), DEGRADE GRACEFULLY (the design
 *                    contract: an LSP that won't start is worse UX than one
 *                    that warns).
 *   5. seccomp     — deliberately NOT installed in this iteration. The allow
 *                    set must be tuned against a real server+reflect.so run;
 *                    a too-tight filter is a cryptic SIGSYS at startup. See
 *                    docs/design/SANDBOX-CROSSPLATFORM.md.
 *   6. execve      — into this role's impl script, resolved as the sibling of
 *                    this launcher's real on-disk path (/proc/self/exe).
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

/* ── role dispatch ────────────────────────────────────────────────────────── */
/* One launcher binary, installed under each user-facing name. WHICH executable
 * we are is decided by our OWN real basename (from /proc/self/exe — kernel
 * truth, not the spoofable argv[0], not env). The name selects the impl script
 * we exec and whether the Landlock FS wall applies. */
struct role {
    const char *name;    /* our installed basename */
    const char *target;  /* impl script we exec, a sibling in our own bindir */
    int         fs_wall; /* 1: install the Landlock FS allow-list. 0: process
                          * hardening only — the build/fetch FS footprint is not
                          * yet walled (mruby_root can live outside the
                          * workspace; a too-tight wall would fail the build,
                          * and a failed build is the one forbidden outcome).
                          * See docs/design/SANDBOX-CROSSPLATFORM.md. */
};
static const struct role ROLES[] = {
    { "mruby-lsp",        "mruby-lsp-server",      1 },
    { "mruby-lsp-setup",  "mruby-lsp-setup-impl",  0 },
    { "mruby-lsp-update", "mruby-lsp-update-impl", 0 },
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

/* ── target resolution: the impl script, next to our REAL path ────────────── */
/* Resolved exclusively from /proc/self/exe — the kernel's record of the binary
 * actually running, which neither an env var nor a spoofed argv[0] can forge.
 * The install hook co-places each impl script in the same bindir as this
 * launcher (and self_gemhome's dirname^2 of the same path is the gem root, so
 * the target always sits under the Landlock RX rule). No PATH search, no env
 * override: either it is our sibling, or we fail loudly. */
static char *resolve_target(const char *target_name)
{
    char exe[4096];
    ssize_t r = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (r <= 0) return NULL;
    exe[r] = '\0';
    char *slash = strrchr(exe, '/');
    if (!slash) return NULL;
    *slash = '\0';                       /* exe -> our bindir */
    char cand[sizeof exe + 64];
    int wrote = snprintf(cand, sizeof cand, "%s/%s", exe, target_name);
    if (wrote < 0 || (size_t)wrote >= sizeof cand) return NULL;
    if (access(cand, X_OK) == 0) return strdup(cand);
    return NULL;
}

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

static int apply_landlock(const char *workspace)
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

    /* Build the access mask in chunks: only ABI ≥ N bits get added. */
    uint64_t fs_all =
        LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
        LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR |
        LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR |
        LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG |
        LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO |
        LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM |
        LANDLOCK_ACCESS_FS_EXECUTE;
#ifdef LANDLOCK_ACCESS_FS_REFER
    if (abi >= 2) fs_all |= LANDLOCK_ACCESS_FS_REFER;
#endif
#ifdef LANDLOCK_ACCESS_FS_TRUNCATE
    if (abi >= 3) fs_all |= LANDLOCK_ACCESS_FS_TRUNCATE;
#endif

    uint64_t rx = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
                  LANDLOCK_ACCESS_FS_EXECUTE;
    uint64_t r  = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
    uint64_t rw = fs_all; /* read+write+exec; we don't try to forbid e.g. exec
                             inside the workspace because mrbc lives there */

    struct landlock_ruleset_attr ra = { .handled_access_fs = fs_all };
    int ruleset_fd = syscall(__NR_landlock_create_ruleset, &ra, sizeof(ra), 0);
    if (ruleset_fd < 0) {
        vlog("landlock: create_ruleset failed: %s — degrading", strerror(errno));
        return -1;
    }

    /* System paths: libraries, locale, /etc bits, /proc, /sys, /dev safe nodes. */
    add_path_rule(ruleset_fd, "/usr",      rx);
    add_path_rule(ruleset_fd, "/bin",      rx);
    add_path_rule(ruleset_fd, "/sbin",     rx);
    add_path_rule(ruleset_fd, "/lib",      r);
    add_path_rule(ruleset_fd, "/lib64",    r);
    add_path_rule(ruleset_fd, "/lib32",    r);
    add_path_rule(ruleset_fd, "/opt",      rx);
    add_path_rule(ruleset_fd, "/etc",      r);
    add_path_rule(ruleset_fd, "/proc",     r);
    add_path_rule(ruleset_fd, "/sys",      r);
    /* /dev: read everywhere (urandom/zero/tty/random reads); write only on
     * the safe sink nodes (null, tty). Granting /dev RW wholesale would also
     * permit writes to block devices etc. — keep those denied by listing the
     * writable ones individually. Underlying Unix DAC still applies, so even
     * /dev/null RW only succeeds because it's world-writable; this rule just
     * makes Landlock not veto the write that RubyGems' resolver (and many
     * Ruby libs) does to File::NULL on startup. */
    add_path_rule(ruleset_fd, "/dev",      r);
    add_path_rule(ruleset_fd, "/dev/null",
                  LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE);
    add_path_rule(ruleset_fd, "/dev/tty",
                  LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE);

    /* /tmp: Ruby and gems put tempfiles here. RW. */
    add_path_rule(ruleset_fd, "/tmp",      rw);
    add_path_rule(ruleset_fd, "/var/tmp",  rw);
    add_path_rule(ruleset_fd, "/run",      r);

    /* User cache/data: FIXED XDG defaults under the passwd home. We do NOT read
     * $XDG_CACHE_HOME / $XDG_DATA_HOME / $HOME — those are env and could
     * relocate a writable root into the sandbox. A user who relocated XDG via
     * env is deliberately not honored here; the server side matches this so the
     * build cache lands where the allow-list expects it. */
    const char *home = real_home();
    if (home) {
        char p[4096];
        snprintf(p, sizeof p, "%s/.cache/mruby-lsp", home);
        add_path_rule(ruleset_fd, p, rw);
        snprintf(p, sizeof p, "%s/.local/share/mruby-lsp", home);
        add_path_rule(ruleset_fd, p, rw);
        /* Ruby version managers commonly drop shims/binstubs under the home: */
        snprintf(p, sizeof p, "%s/.rbenv", home); add_path_rule(ruleset_fd, p, rx);
        snprintf(p, sizeof p, "%s/.rvm",   home); add_path_rule(ruleset_fd, p, rx);
        snprintf(p, sizeof p, "%s/.asdf",  home); add_path_rule(ruleset_fd, p, rx);
        snprintf(p, sizeof p, "%s/.gem",   home); add_path_rule(ruleset_fd, p, rx);
        snprintf(p, sizeof p, "%s/.local/share/gem", home);
        add_path_rule(ruleset_fd, p, rx);
    }

    /* The workspace itself: R (the server reads files; setup writes build
     * artifacts to the cache, not the workspace). */
    if (workspace && *workspace) {
        add_path_rule(ruleset_fd, workspace, r);
    }

    /* The launcher's own gem-install root (RX). Without this, execv() of the
     * sibling `mruby-lsp-server` binstub fails with EACCES under Landlock —
     * the launcher itself was loaded before the wall went up, but anything
     * exec'd afterward needs an explicit allow. This single rule covers
     * <gemhome>/{bin,gems,specifications,extensions}, which is everything the
     * binstub + Ruby's require chain reach. Works for any gem install layout
     * (system, user --user-install, --install-dir <bundled>). */
    char gemhome[4096];
    if (self_gemhome(gemhome, sizeof gemhome) == 0) {
        add_path_rule(ruleset_fd, gemhome, rx);
        vlog("landlock: gem root RX = %s", gemhome);
    }

    if (syscall(__NR_landlock_restrict_self, ruleset_fd, 0)) {
        vlog("landlock: restrict_self failed: %s — degrading", strerror(errno));
        close(ruleset_fd);
        return -1;
    }
    close(ruleset_fd);
    vlog("landlock: active");
    return 0;
}
#else  /* !MRUBY_LSP_HAVE_LANDLOCK — kernel headers can't name the syscalls */
static int apply_landlock(const char *workspace)
{
    (void)workspace;
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

    /* The workspace, if the editor passed one. The server also accepts rootUri
     * via the LSP initialize; we just use this for the Landlock allow list.
     * argv (set by the launching editor) is not env — it does not steer the
     * security floor, only narrows the readable workspace. */
    const char *workspace = (argc > 1 && argv[1][0] == '/') ? argv[1] : NULL;

    close_stray_fds();
    scrub_env();

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
        vlog("PR_SET_NO_NEW_PRIVS failed: %s", strerror(errno));

    if (role->fs_wall) {
        if (apply_landlock(workspace) < 0) {
            /* Per the design: never fail-closed on a sandbox setup error. The
             * env-scrub and NNP bits above already happened. */
            vlog("landlock: not active — %s runs with env-scrub + NNP only",
                 role->name);
        }
    } else {
        /* Build/fetch roles: process hardening only this iteration. The FS wall
         * waits on the fetch/build dir split so it can't fail the build. */
        vlog("role %s: process hardening only (FS wall deferred)", role->name);
    }

    /* seccomp: deferred (see docs/design/SANDBOX-CROSSPLATFORM.md). */

    /* Resolve and exec the impl — strictly our on-disk sibling. */
    char *target = resolve_target(role->target);
    if (!target) {
        fprintf(stderr,
                "mruby-lsp: could not locate '%s' next to this launcher. It must "
                "be co-installed in the same bindir (resolved via /proc/self/exe, "
                "not PATH).\n", role->target);
        return 127;
    }

    /* Build new argv: keep argv[1..] but exec target instead of self. */
    char **new_argv = calloc((size_t)argc + 1, sizeof(char *));
    if (!new_argv) { perror("calloc"); return 1; }
    new_argv[0] = target;
    for (int i = 1; i < argc; i++) new_argv[i] = argv[i];
    new_argv[argc] = NULL;

    vlog("execve %s", target);
    execv(target, new_argv);
    fprintf(stderr, "mruby-lsp: execv(%s): %s\n",
            target, strerror(errno));
    return 127;
}
