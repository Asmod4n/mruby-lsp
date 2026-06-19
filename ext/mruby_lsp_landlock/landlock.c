/*
 * mruby-lsp — stage-2 Landlock: the READ wall the SERVER raises after it learns
 * the workspace from the LSP `initialize` request.
 *
 * Why a C extension and not FFI/Fiddle: the Landlock syscall numbers are
 * architecture-specific (__NR_landlock_* differs per arch), so a blind
 * Fiddle.syscall would invoke the WRONG syscall on the wrong arch. The kernel
 * headers know the right numbers at BUILD time. And if the headers don't even
 * name Landlock (kernel < 5.13 / no headers), this whole module is compiled out:
 * Init_ defines NOTHING, so `defined?(MrubyLsp::Landlock)` is nil and the server
 * treats it as "no second wall available here" — exactly the same degrade path
 * the C launcher uses for stage 1.
 *
 * Two-stage model (see docs/design/SANDBOX-CROSSPLATFORM.md):
 *   stage 1 — the launcher, BEFORE Ruby: seccomp + NoNewPrivs + a Landlock layer
 *             that confines WRITES/EXEC (it can't scope READS — it doesn't know
 *             the workspace yet, and the only spec-portable source of the
 *             workspace is the `initialize` request, which hasn't arrived).
 *   stage 2 — HERE, in the server, AFTER `initialize`: stack a Landlock layer
 *             that handles READ_FILE|READ_DIR and grants it only on the project
 *             (workspace + mruby_root) plus the dirs Ruby itself needs. Landlock
 *             layers are AND-combined, so this can only NARROW reads, never widen
 *             — safe to stack on top of stage 1.
 */

#define _GNU_SOURCE
#include <ruby.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#if defined(__has_include)
# if __has_include(<linux/landlock.h>)
#  include <linux/landlock.h>
#  define MRUBY_LSP_LANDLOCK_HDR 1
# endif
#endif

/* The build decides availability, never a guessed syscall number. Overridable
 * with -DMRUBY_LSP_HAVE_LANDLOCK=0/1 (forcing off is how the stub path is tested
 * on a host that does have the headers). */
#ifndef MRUBY_LSP_HAVE_LANDLOCK
# if defined(MRUBY_LSP_LANDLOCK_HDR) && \
     defined(__NR_landlock_create_ruleset) && \
     defined(__NR_landlock_add_rule) && \
     defined(__NR_landlock_restrict_self)
#  define MRUBY_LSP_HAVE_LANDLOCK 1
# else
#  define MRUBY_LSP_HAVE_LANDLOCK 0
# endif
#endif

#if MRUBY_LSP_HAVE_LANDLOCK

# ifndef LANDLOCK_CREATE_RULESET_VERSION
#  define LANDLOCK_CREATE_RULESET_VERSION (1U << 0)
# endif

static long ll_create_ruleset(const struct landlock_ruleset_attr *attr,
                              size_t size, uint32_t flags)
{
    return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}
static long ll_add_rule(int fd, enum landlock_rule_type t,
                        const void *attr, uint32_t flags)
{
    return syscall(__NR_landlock_add_rule, fd, t, attr, flags);
}
static long ll_restrict_self(int fd, uint32_t flags)
{
    return syscall(__NR_landlock_restrict_self, fd, flags);
}

/* Grant `access` beneath `path`. A path that can't be opened (missing) simply
 * contributes no rule — never an error (a project may legitimately lack, say,
 * a separate mruby_root). */
static void add_path(int ruleset_fd, const char *path, uint64_t access)
{
    int pfd = open(path, O_PATH | O_CLOEXEC);
    if (pfd < 0) return;
    struct landlock_path_beneath_attr pb = {
        .allowed_access = access,
        .parent_fd = pfd,
    };
    ll_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &pb, 0);
    close(pfd);
}

/* MrubyLsp::Landlock.abi -> Integer (supported ABI) or nil when the running
 * kernel has no Landlock (build had the headers, runtime returns ENOSYS). */
static VALUE rb_abi(VALUE self)
{
    (void)self;
    long abi = ll_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 0) return Qnil;
    return LONG2NUM(abi);
}

/* MrubyLsp::Landlock.restrict_reads(paths) -> true
 *
 * Stacks a Landlock layer that handles READ_FILE|READ_DIR and allows them ONLY
 * beneath a baked base set (the system/Ruby dirs the interpreter needs) plus
 * each caller-supplied path (workspace, mruby_root, cache, gem dirs, home data).
 * Every read outside that union is denied from here on, for this process and
 * its children. Raises Errno::* on a real failure (e.g. ENOSYS) — the caller
 * MUST see that, never swallow it. */
static VALUE rb_restrict_reads(VALUE self, VALUE paths)
{
    (void)self;
    Check_Type(paths, T_ARRAY);

    const uint64_t read_set =
        LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;

    struct landlock_ruleset_attr ra = { .handled_access_fs = read_set };
    long fd = ll_create_ruleset(&ra, sizeof(ra), 0);
    if (fd < 0) rb_sys_fail("landlock_create_ruleset");
    int ruleset_fd = (int)fd;

    /* System + pseudo-filesystems the interpreter, its stdlib, and the C
     * toolchain (the server may spawn the setup build) read from. Mirrors the
     * launcher's stage-1 list; missing entries are skipped. */
    static const char *const base[] = {
        "/usr", "/bin", "/sbin", "/lib", "/lib64", "/lib32", "/opt", "/etc",
        "/proc", "/sys", "/dev", "/tmp", "/var/tmp", "/run", NULL
    };
    for (const char *const *p = base; *p; p++) add_path(ruleset_fd, *p, read_set);

    /* Dynamic paths from the server: workspace (from initialize rootUri),
     * mruby_root, the build cache, every Gem.path, the Ruby prefix, home data. */
    for (long i = 0; i < RARRAY_LEN(paths); i++) {
        VALUE s = rb_ary_entry(paths, i);
        if (NIL_P(s)) continue;
        add_path(ruleset_fd, StringValueCStr(s), read_set);
    }

    if (ll_restrict_self(ruleset_fd, 0) != 0) {
        int e = errno;
        close(ruleset_fd);
        errno = e;
        rb_sys_fail("landlock_restrict_self");
    }
    close(ruleset_fd);
    return Qtrue;
}

#endif /* MRUBY_LSP_HAVE_LANDLOCK */

void Init_mruby_lsp_landlock(void)
{
#if MRUBY_LSP_HAVE_LANDLOCK
    VALUE mMrubyLsp = rb_define_module("MrubyLsp");
    VALUE mLandlock = rb_define_module_under(mMrubyLsp, "Landlock");
    rb_define_singleton_method(mLandlock, "abi", rb_abi, 0);
    rb_define_singleton_method(mLandlock, "restrict_reads", rb_restrict_reads, 1);
#else
    /* No Landlock at build time: define NOTHING. The require still succeeds (the
     * .so loads), but `defined?(MrubyLsp::Landlock)` is nil, so the server knows
     * there is no stage-2 wall to raise on this host and degrades (as on macOS/
     * Windows or an old kernel). */
#endif
}
