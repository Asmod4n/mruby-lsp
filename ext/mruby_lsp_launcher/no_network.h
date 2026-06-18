/*
 * no_network.h — a tiny seccomp-BPF filter that denies creation of AF_INET /
 * AF_INET6 sockets (no external network) while leaving AF_UNIX, pipes, and all
 * file I/O intact. Shared by the launcher (server role) and the mruby-lsp-nonet
 * wrapper (offline build phase).
 *
 * Why deny by socket DOMAIN, not by blocking socket(2) outright: the build and
 * the server still use Unix-domain sockets / pipes for local IPC; only IP
 * networking must die. seccomp can read socket()'s first arg (the domain) — a
 * scalar, no TOCTOU pointer hazard — so we filter precisely.
 *
 * Degrade-safe: a no-op (returns 0) on arches whose syscall numbers we don't
 * hardcode, and returns -1 (caller logs + continues) if seccomp is unavailable.
 * Requires PR_SET_NO_NEW_PRIVS already set OR sets it here.
 */
#ifndef MRUBY_LSP_NO_NETWORK_H
#define MRUBY_LSP_NO_NETWORK_H

#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>

#if defined(__has_include)
# if __has_include(<linux/seccomp.h>) && __has_include(<linux/filter.h>) && \
     __has_include(<linux/audit.h>)
#  include <linux/seccomp.h>
#  include <linux/filter.h>
#  include <linux/audit.h>
#  define MRUBY_LSP_HAVE_SECCOMP 1
# endif
#endif

/* The audit arch constant for THIS build. We only emit a filter for arches
 * whose __NR_socket we can trust at compile time; elsewhere the filter is a
 * no-op (never a wrong-syscall-number hazard). */
#if defined(__x86_64__)
# define MRUBY_LSP_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
# define MRUBY_LSP_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
# define MRUBY_LSP_AUDIT_ARCH 0
#endif

/* 0 = installed (or deliberately a no-op on an unsupported arch),
 * -1 = seccomp present but install failed (caller logs and continues). */
static int install_no_network_seccomp(void)
{
#if !defined(MRUBY_LSP_HAVE_SECCOMP) || MRUBY_LSP_AUDIT_ARCH == 0
    return 0; /* no headers, or an arch we won't risk a hand-built filter on */
#else
    struct sock_filter f[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, MRUBY_LSP_AUDIT_ARCH, 0, 7), /* foreign arch -> ALLOW */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 5),         /* not socket -> ALLOW */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_INET, 2, 0),            /* AF_INET  -> ERRNO */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_INET6, 1, 0),           /* AF_INET6 -> ERRNO */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),                  /* AF_UNIX &c. ok */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),                  /* default ALLOW */
    };
    struct sock_fprog prog = {
        .len = (unsigned short)(sizeof f / sizeof f[0]),
        .filter = f,
    };
    /* NO_NEW_PRIVS is the precondition for unprivileged seccomp; harmless to
     * (re)assert. */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0)) return -1;
    return 0;
#endif
}

#endif /* MRUBY_LSP_NO_NETWORK_H */
