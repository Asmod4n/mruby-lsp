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
 * Degrade-safe: if seccomp can't be installed (old kernel, container policy),
 * we log to stderr and exec anyway — a build that won't run is worse than one
 * that runs without the net seal. The fetch/build FS split still stands.
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
        fprintf(stderr, "usage: mruby-lsp-nonet <command> [args...]\n");
        return 2;
    }
    if (install_no_network_seccomp() != 0) {
        fprintf(stderr, "mruby-lsp-nonet: seccomp unavailable (%s); "
                        "running without the network seal\n", strerror(errno));
    }
    execvp(argv[1], &argv[1]);
    fprintf(stderr, "mruby-lsp-nonet: exec %s: %s\n", argv[1], strerror(errno));
    return 127;
}
