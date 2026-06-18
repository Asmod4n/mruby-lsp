/* mruby leg -- exported declarations. Include from an mruby-only TU. Names only
 * mrb_value/mrb_state + the neutral vb_value, never ruby.h. This is the header
 * the mgem puts on a dependent's include path so a consumer can bridge without
 * pulling CRuby macros into the same file. */
#ifndef VALUE_BRIDGE_MRUBY_H
#define VALUE_BRIDGE_MRUBY_H
#include <mruby.h>
#include "vb.h"
#ifdef __cplusplus
extern "C" {
#endif
vb_value *vb_from_mrb(mrb_state *mrb, mrb_value v);       /* produce */
mrb_value vb_to_mrb(mrb_state *mrb, const vb_value *v);   /* consume */
#ifdef __cplusplus
}
#endif
#endif
