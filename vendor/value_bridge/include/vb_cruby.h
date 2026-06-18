/* CRuby leg -- exported declarations. Include this (NOT vb_cruby.c's internals)
 * from a CRuby-only translation unit. Names only VALUE + the neutral vb_value,
 * so it never has to coexist with mruby.h. */
#ifndef VALUE_BRIDGE_CRUBY_H
#define VALUE_BRIDGE_CRUBY_H
#include <ruby.h>
#include <stdint.h>
#include "vb.h"
#ifdef __cplusplus
extern "C" {
#endif
vb_value *vb_from_value(VALUE v);          /* produce: VALUE -> vb_value (owned tree) */
VALUE     vb_to_value(const vb_value *v);  /* consume: vb_value -> VALUE */

#ifdef __cplusplus
}
#endif
#endif
