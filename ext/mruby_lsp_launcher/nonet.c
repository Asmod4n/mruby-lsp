/*
 * mruby-lsp-nonet — run a command with external network denied.
 *
 *   mruby-lsp-nonet <cmd> [args...]
 *
 * Installs the AF_INET/AF_INET6 seccomp filter (see no_network.h), then execs
 * the given command. Used by mruby-lsp-setup to run the OFFLINE build phase: the
 * fetch phase clones gems WITH network into the fetch/ dir, then the build runs
 * under this wrapper so a malicious mrbgem.rake / gcc plugin in fetched code
 * can't phone home or pull more code. Local IPC (Unix sockets, pipes) and all
 * file I/O still work, so the build itself is unaffected.
 *
 * Fail-closed: a successful seal is the ONLY licence to exec. If seccomp can't
 * be installed (old kernel, container policy, unhardcoded arch) we DO NOT run
 * the build unsealed — we log and exit non-zero. Deciding whether to build
 * anyway (with the user's consent) belongs to mruby-lsp-setup, which probes us
 * with --check first. A silent unsealed build is the one outcome we refuse.
 *
 *   mruby-lsp-nonet --check     -> install the seal, exit 0 if it engaged, else
 *                                  1; runs NOTHING (a probe for the seal's
 *                                  availability on this host/arch).
 *
 * Linux-only; the build wraps with this only where it exists.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include "no_network.h"

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: mruby-lsp-nonet [--check] <command> [args...]\n");
        return 2;
    }

    /* Probe: install the seal and report via exit status WITHOUT running
     * anything. setup calls this to learn whether the build can be sealed on
     * THIS host/arch -- 0 = sealable, non-0 = not. */
    if (strcmp(argv[1], "--check") == 0) {
        return install_no_network_seccomp() == 0 ? 0 : 1;
    }

    /* Fail-closed: 0 is the ONLY licence to exec. -1 (seccomp failed) or 1
     * (unsealable arch/no headers) => refuse to run the build unsealed. */
    int rc = install_no_network_seccomp();
    if (rc != 0) {
        fprintf(stderr, "mruby-lsp-nonet: cannot seal the network (%s); "
                        "refusing to run the build unsealed\n",
                rc < 0 ? strerror(errno) : "unsupported kernel/CPU architecture");
        return 69; /* EX_UNAVAILABLE */
    }
    execvp(argv[1], &argv[1]);
    fprintf(stderr, "mruby-lsp-nonet: exec %s: %s\n", argv[1], strerror(errno));
    return 127;
}
