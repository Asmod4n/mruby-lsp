/* CRuby extension entry point.
 *
 * The substance of this gem is the C converter library (vb.c + vb_cruby.c, and,
 * when a libmruby is found, vb_mruby.c) plus the exported headers other native
 * extensions link against. This Init establishes the ValueBridge module (so the
 * C legs can find ValueBridge::Tagged) and installs a test-only roundtrip hook
 * used to exercise the CRuby leg end-to-end in-process.
 */
#include "vb_cruby.h"   /* ruby.h + vb.h + the leg's declarations */

/* TEST/DEBUG: VALUE -> vb_value -> VALUE, proving producer + consumer agree.
 * Same-runtime roundtrip exercises every tag, the utf8/bytes split, arrays,
 * nesting,  */
static VALUE rb_roundtrip(VALUE self, VALUE obj) {
  (void)self;
  vb_value *v = vb_from_value(obj);
  VALUE out = vb_to_value(v);
  vb_free(v);
  return out;
}

void Init_value_bridge_ext(void) {
  VALUE m = rb_define_module("ValueBridge");
  rb_define_singleton_method(m, "__roundtrip", rb_roundtrip, 1);
}
