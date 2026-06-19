# frozen_string_literal: true

# Builds the stage-2 Landlock read-wall extension (lib: MrubyLsp::Landlock).
#
# Availability is decided in landlock.c at COMPILE time via __has_include +
# __NR_landlock_* (never a guessed syscall number). We probe the header here only
# so the build log records it; the .c is self-contained. The .so is ALWAYS
# produced — on a host without the headers it is a stub whose Init_ defines
# nothing, so `require` still succeeds and the server learns "no stage-2 wall
# here" from `defined?(MrubyLsp::Landlock)` being nil (same degrade path as an old
# kernel or macOS/Windows).
require "mkmf"

have_header("linux/landlock.h")

create_makefile("mruby_lsp_landlock")
