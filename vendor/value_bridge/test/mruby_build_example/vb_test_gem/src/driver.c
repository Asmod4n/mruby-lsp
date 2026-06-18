/* Consumer gem: includes ONLY the exported mruby header -- no ruby.h anywhere --
 * and bridges through the neutral vb_value. Proves the export/firewall works. */
#include "vb_mruby.h"   /* mruby.h + vb.h + vb_from_mrb/vb_to_mrb + vb_free */
#include <mruby/class.h>

static mrb_value vb_test_roundtrip(mrb_state *mrb, mrb_value self) {
  (void)self;
  mrb_value obj;
  mrb_get_args(mrb, "o", &obj);
  vb_value *v = vb_from_mrb(mrb, obj);   /* produce */
  mrb_value out = vb_to_mrb(mrb, v);     /* consume */
  vb_free(v);
  return out;
}

void mrb_mruby_vb_test_gem_init(mrb_state *mrb) {
  struct RClass *m = mrb_define_module(mrb, "ValueBridge"); /* idempotent */
  mrb_define_class_method(mrb, m, "__roundtrip", vb_test_roundtrip, MRB_ARGS_REQ(1));
}
void mrb_mruby_vb_test_gem_final(mrb_state *mrb) { (void)mrb; }
