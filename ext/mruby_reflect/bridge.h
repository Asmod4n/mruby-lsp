#ifndef MRUBY_REFLECT_BRIDGE_H
#define MRUBY_REFLECT_BRIDGE_H
#include <stddef.h>
#include "vb.h"   /* the neutral cross-TU currency (value_bridge) */

/* Plain-C boundary. No Ruby/mruby types cross -- only the neutral vb_value.
 * NO eval: the host hands over NAMES (data); each op resolves the name via
 * mrb_str_constantize and calls a FIXED reflection method via mrb_funcall.
 * ONE function per op -- there is no flag and no dispatch here; Ruby decides
 * which op (instance vs singleton) to call and invokes it directly.
 * Each op returns an owned vb_value tree (caller frees it with vb_free) or NULL
 * for nil/absent/exception. mruby_tu builds the result mrb_value and converts it
 * with vb_from_mrb; bridge_tu materializes it into a Ruby value with vb_to_value.
 * Reflection results keep their real types: method/constant lists are Symbols,
 * ancestors are CLASS tags (payload = name), source_location is [String,Integer],
 * parameters is [[Symbol,Symbol]], addresses are Integers. */
void *mrb_bridge_open(void);
void  mrb_bridge_close(void *handle);

vb_value *mrb_bridge_ancestors(void *h, const char *cls, size_t clen);
vb_value *mrb_bridge_instance_methods(void *h, const char *cls, size_t clen, int include_super);
vb_value *mrb_bridge_private_instance_methods(void *h, const char *cls, size_t clen, int include_super);
vb_value *mrb_bridge_constants(void *h, const char *cls, size_t clen);
vb_value *mrb_bridge_singleton_methods(void *h, const char *cls, size_t clen, int include_super);
vb_value *mrb_bridge_anchor_addr(void *h);
vb_value *mrb_bridge_platform(void *h);  /* [Platform::OS, Platform::Toolchain] or NULL */
vb_value *mrb_bridge_net_schema(void *h, const char *cls, size_t clen);  /* {:@ivar=>[Class,...]} Hash or NULL (mruby-native-ext-type) */

vb_value *mrb_bridge_source_location(void *h, const char *cls, size_t clen,
                                     const char *meth, size_t mlen);
vb_value *mrb_bridge_return_type(void *h, const char *cls, size_t clen,
                                 const char *meth, size_t mlen);
vb_value *mrb_bridge_singleton_return_type(void *h, const char *cls, size_t clen,
                                           const char *meth, size_t mlen);
vb_value *mrb_bridge_singleton_source_location(void *h, const char *cls, size_t clen,
                                               const char *meth, size_t mlen);
vb_value *mrb_bridge_parameters(void *h, const char *cls, size_t clen,
                                const char *meth, size_t mlen);
vb_value *mrb_bridge_singleton_parameters(void *h, const char *cls, size_t clen,
                                          const char *meth, size_t mlen);
vb_value *mrb_bridge_cfunc_addr(void *h, const char *cls, size_t clen,
                                const char *meth, size_t mlen);
vb_value *mrb_bridge_singleton_cfunc_addr(void *h, const char *cls, size_t clen,
                                          const char *meth, size_t mlen);
#endif
