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
 * Return contract is THREE-way and never lies that a seal is up when it isn't:
 *    0  — filter installed (network sealed).
 *   -1  — seccomp present but the install syscall failed (errno set).
 *    1  — cannot seal on THIS build: no seccomp headers, or an arch whose
 *         __NR_socket we won't hardcode. The caller must treat this as UNSEALED
 *         (fail-closed / ask consent) — NOT as success.
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

/* KILL_PROCESS (>= 4.14) nukes every thread; on older headers fall back to
 * SECCOMP_RET_KILL (thread). A foreign-arch syscall here means a compat-ABI
 * bypass attempt, so killing is the correct, standard response. */
#if defined(MRUBY_LSP_HAVE_SECCOMP) && !defined(SECCOMP_RET_KILL_PROCESS)
# define SECCOMP_RET_KILL_PROCESS SECCOMP_RET_KILL
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

/*  0 = installed,  -1 = seccomp present but install failed,
 *  1 = cannot seal on this build (no headers / unhardcoded arch) — UNSEALED. */
static int install_no_network_seccomp(void)
{
#if !defined(MRUBY_LSP_HAVE_SECCOMP) || MRUBY_LSP_AUDIT_ARCH == 0
    return 1; /* no headers, or an arch we won't risk a hand-built filter on:
               * report UNSEALED so the caller fails closed, never a silent pass */
#else
    /* Foreign-arch syscalls (e.g. i386/x32 on an x86_64 kernel) must NOT slip
     * through: a JEQ-mismatch -> ALLOW would let a compat-ABI socket() bypass
     * the seal. Mismatch -> KILL_PROCESS instead. A legit native build never
     * issues foreign-arch syscalls. */
    struct sock_filter f[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, MRUBY_LSP_AUDIT_ARCH, 0, 8), /* foreign arch -> KILL */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 5),         /* not socket -> ALLOW */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_INET, 2, 0),            /* AF_INET  -> ERRNO */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_INET6, 1, 0),           /* AF_INET6 -> ERRNO */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),                  /* AF_UNIX &c. ok */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),                  /* not-socket -> ALLOW */
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),           /* foreign arch */
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
