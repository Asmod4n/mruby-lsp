/* mruby-platform: compile-time platform/toolchain facts as Ruby constants.
 *
 * The #ifdefs below are resolved by the compiler that builds this gem into
 * libmruby. So the constants describe the toolchain and OS that produced THIS
 * mruby -- not the host of any embedder, and not a runtime guess. Read them
 * from Ruby as plain symbol constants:
 *
 *     Platform::OS         # => :linux | :macos | :windows | :freebsd | :netbsd
 *                          #    | :openbsd | :dragonfly | :unknown
 *     Platform::Toolchain  # => :gcc | :clang | :msvc | :unknown
 *
 * Values use MRB_SYM(): compile-time symbol constants, no runtime intern. The
 * presym scanner self-registers them (MRB_SYM expands to a tag during scanning),
 * and since it scans the preprocessed source it only ever sees the same active
 * #ifdef branch the real compile sees -- self-consistent per platform. More
 * compile-time facts (arch, word size, endianness, ...) add the same way.
 *
 * Defined with mrb_define_const_id (presym names too) and the module is frozen
 * afterward so the constants are read-only.
 */
#include <mruby.h>
#include <mruby/variable.h>
#include <mruby/presym.h>

void
mrb_mruby_platform_gem_init(mrb_state *mrb)
{
  struct RClass *m = mrb_define_module(mrb, "Platform");

#if defined(_WIN32)
  mrb_sym os = MRB_SYM(windows);
#elif defined(__APPLE__)
  mrb_sym os = MRB_SYM(macos);
#elif defined(__linux__)
  mrb_sym os = MRB_SYM(linux);
/* DragonFly before FreeBSD: it derives from FreeBSD 4 and some compat layers
 * define __FreeBSD__, but __DragonFly__ is the authoritative marker. */
#elif defined(__DragonFly__)
  mrb_sym os = MRB_SYM(dragonfly);
#elif defined(__FreeBSD__)
  mrb_sym os = MRB_SYM(freebsd);
#elif defined(__NetBSD__)
  mrb_sym os = MRB_SYM(netbsd);
#elif defined(__OpenBSD__)
  mrb_sym os = MRB_SYM(openbsd);
#else
  mrb_sym os = MRB_SYM(unknown);
#endif

  /* _MSC_VER first: clang-cl defines both _MSC_VER and __clang__ and emits PDB
   * like MSVC, so it belongs in the msvc bucket. __clang__ before __GNUC__
   * because clang also defines __GNUC__. */
#if defined(_MSC_VER)
  mrb_sym toolchain = MRB_SYM(msvc);
#elif defined(__clang__)
  mrb_sym toolchain = MRB_SYM(clang);
#elif defined(__GNUC__)
  mrb_sym toolchain = MRB_SYM(gcc);
#else
  mrb_sym toolchain = MRB_SYM(unknown);
#endif

  mrb_define_const_id(mrb, m, MRB_SYM(OS),        mrb_symbol_value(os));
  mrb_define_const_id(mrb, m, MRB_SYM(Toolchain), mrb_symbol_value(toolchain));

  /* Lock the namespace: const-set checks mrb_check_frozen on the target, so a
   * frozen module rejects (re)assignment -- Platform::OS / Toolchain can be read
   * but never changed. (The symbol values are immutable already.) Freeze AFTER
   * defining; freezing first would make the defines themselves raise. */
  mrb_obj_freeze(mrb, mrb_obj_value(m));
}

void
mrb_mruby_platform_gem_final(mrb_state *mrb) { (void)mrb; }
