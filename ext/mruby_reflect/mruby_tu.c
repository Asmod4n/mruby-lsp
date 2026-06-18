/* The ONLY translation unit that touches mruby. Resolves a host-supplied NAME
 * to a class via mrb_str_constantize, calls a FIXED reflection method, and hands
 * the result mrb_value to value_bridge (vb_from_mrb) -- the neutral currency the
 * CRuby TU then materializes. No emit protocol, no eval, no marshalling here.
 *
 * ONE METHOD PER OP. No central dispatch: no op tag, no switch, no function-
 * pointer selection (a writable indirect call target is exactly what we don't
 * want near a VM boundary). Each op is its own pair -- a branch-free body and a
 * thin entry that names THAT body, directly, to mrb_protect_error. The repeated
 * protect dance is spelled once as RUN_OP; the body argument is always a literal
 * callback name, so it stays a direct call, never a dispatch. Ruby decides which
 * op to call (instance vs singleton are separate ops); C never chooses.
 *
 * Results keep their real types: method/constant lists -> Symbols, ancestors ->
 * CLASS tags (payload = name), source_location -> [String,Integer], parameters
 * -> [[Symbol,Symbol]], addresses -> exact Integers (via mruby-c-ext-helpers,
 * promoting to Bigint when an address exceeds mrb_int). value_bridge owns the
 * conversion + crash-safety contract; every funcall runs inside mrb_protect_error. */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/array.h>
#include <mruby/variable.h>  /* mrb_const_get */
#include <mruby/string.h>
#include <mruby/error.h>      /* mrb_protect_error, E_TYPE_ERROR */
#include <mruby/proc.h>       /* mrb_method_search_vm, MRB_METHOD_CFUNC_P/_CFUNC */
#include <mruby/presym.h>     /* MRB_SYM(...) */
#include <stdint.h>
#include <stdlib.h>
#include "vb_mruby.h"         /* vb_from_mrb / vb_free (+ mruby.h + vb.h) */
#include "bridge.h"

#if defined(__has_include)
#  if __has_include(<mruby/num_helpers.h>)
#    include <mruby/num_helpers.h>      /* mrb_convert_uint64 */
#    define HAVE_NUM_HELPERS 1
#  endif
#endif

/* Persistent handle: one VM + the arena baseline. Each op resets the arena to
 * the baseline on entry, freeing the previous op's temporaries (already copied
 * out by the CRuby side) so reflecting a whole VM stays memory-bounded, while
 * THIS op's borrowed strings live until the next op runs. */
typedef struct { mrb_state *mrb; int arena_base; } bridge_t;

void *mrb_bridge_open(void) {
  mrb_state *mrb = mrb_open();
  if (!mrb) return NULL;
  bridge_t *b = (bridge_t *)malloc(sizeof *b);
  if (!b) { mrb_close(mrb); return NULL; }
  b->mrb = mrb; b->arena_base = mrb_gc_arena_save(mrb);
  return b;
}
void mrb_bridge_close(void *p) {
  bridge_t *b = (bridge_t *)p;
  if (b) { if (b->mrb) mrb_close(b->mrb); free(b); }
}

typedef struct {
  const char *cls; size_t clen;
  const char *meth; size_t mlen;
  int flag;                 /* include_super */
  vb_value *out;            /* result tree, set inside the protected body */
} req_t;

/* --- converters / guards (the only places a value's shape is inspected) ----
 * value_bridge owns value conversion; these two are the irreducibly mruby bits
 * it can't do: a memory-safety gate before a raw class pointer, and a method ->
 * address read. Neither is control flow over host input -- the gate RAISES (and
 * mrb_protect_error upstream turns that into nil), the predicate RETURNS a value. */

/* address -> exact Integer (Bigint when it exceeds mrb_int; never a lossy Float) */
static mrb_value addr_to_num(mrb_state *mrb, const void *p) {
#ifdef HAVE_NUM_HELPERS
  return mrb_convert_uint64(mrb, (uint64_t)(uintptr_t)p);
#else
  return mrb_int_value(mrb, (mrb_int)(uintptr_t)p);
#endif
}

/* SECURITY: a host name may resolve (via constantize) to anything, or to nil.
 * mrb_class_ptr on a non-class yields a bad pointer that mrb_method_search_vm
 * later dereferences -> a SIGSEGV mrb_protect_error CANNOT catch. So gate the
 * type and RAISE on a miss; protect turns the raise into a clean nil. */
static void ensure_module(mrb_state *mrb, mrb_value v) {
  switch (mrb_type(v)) {
    case MRB_TT_CLASS: case MRB_TT_MODULE: case MRB_TT_SCLASS: return;
    default: mrb_raise(mrb, E_TYPE_ERROR, "not a class or module");
  }
}

/* method -> C function address, or nil when the method isn't C-backed. The
 * MRB_METHOD_* predicate has no Ruby equivalent, so it lives here as a value
 * converter; gate first so mrb_class_ptr is safe. */
static mrb_value cfunc_addr_or_nil(mrb_state *mrb, mrb_value recv,
                                   const char *meth, size_t mlen) {
  ensure_module(mrb, recv);
  struct RClass *c = mrb_class_ptr(recv);
  mrb_method_t m = mrb_method_search_vm(mrb, &c, mrb_intern(mrb, meth, mlen));
  return (!MRB_METHOD_UNDEF_P(m) && MRB_METHOD_CFUNC_P(m))
           ? addr_to_num(mrb, (const void *)MRB_METHOD_CFUNC(m))
           : mrb_nil_value();
}

/* Faithful parameters from a method's ARG SPEC. mruby's Method#parameters is
 * WRONG for C methods: a C-method proc isn't STRICT, so proc.c downgrades every
 * :req to :opt (mrb_proc_parameters line ~219) and a method that takes one
 * REQUIRED arg prints as "(arg1 = ...)". We instead decode the aspec directly,
 * recovering the real req/opt/rest/post/key/block split. C methods carry no
 * parameter NAMES (the renderer supplies argN placeholders), so we emit
 * one-element [kind] specs -- exactly the shape mruby uses for unnamed params.
 * Ruby (irep) methods are left to mruby's own parameters: they're strict (no
 * downgrade) and carry the real names, which we must not throw away. */
static mrb_value aspec_params(mrb_state *mrb, mrb_aspec a) {
  mrb_value arr = mrb_ary_new(mrb);
  int req = MRB_ASPEC_REQ(a), opt = MRB_ASPEC_OPT(a), rest = MRB_ASPEC_REST(a),
      post = MRB_ASPEC_POST(a), key = MRB_ASPEC_KEY(a), kdict = MRB_ASPEC_KDICT(a),
      block = MRB_ASPEC_BLOCK(a), i;
#define KIND(SYM) do { mrb_value e = mrb_ary_new_capa(mrb, 1);             \
    mrb_ary_push(mrb, e, mrb_symbol_value(SYM)); mrb_ary_push(mrb, arr, e); } while (0)
  for (i = 0; i < req;  i++) KIND(MRB_SYM(req));
  for (i = 0; i < opt;  i++) KIND(MRB_SYM(opt));
  if (rest)                  KIND(MRB_SYM(rest));
  for (i = 0; i < post; i++) KIND(MRB_SYM(req));   /* post-positionals are required */
  for (i = 0; i < key;  i++) KIND(MRB_SYM(key));   /* C aspec records no key names */
  if (kdict)                 KIND(MRB_SYM(keyrest));
  if (block)                 KIND(MRB_SYM(block));
#undef KIND
  return arr;
}

/* parameters for (recv, meth): aspec-decoded for C methods (recovering true
 * req/opt/...), mruby's Method#parameters for Ruby methods (correct + named).
 * recv is the already-resolved class/sclass; gate it before mrb_class_ptr so a
 * bad value RAISES (protect -> nil) rather than feeding a junk pointer to the
 * method search. An undefined method falls through to instance_method, which
 * raises and (under protect) becomes nil, exactly as before. */
static mrb_value params_for(mrb_state *mrb, mrb_value recv, const char *meth, size_t mlen) {
  ensure_module(mrb, recv);
  struct RClass *c = mrb_class_ptr(recv);
  mrb_sym sym = mrb_intern(mrb, meth, mlen);
  struct RClass *fc = c;
  mrb_method_t m = mrb_method_search_vm(mrb, &fc, sym);
  if (!MRB_METHOD_UNDEF_P(m) && MRB_METHOD_CFUNC_P(m)) {
    if (MRB_METHOD_FUNC_P(m)) {
      /* func-table entry: aspec lives in the method flags (all mruby versions) */
      return aspec_params(mrb, MRB_MT_ASPEC(m.flags));
    }
#ifdef MRB_PROC_CASPEC_MASK
    /* a proc that wraps a C function: aspec is the compressed caspec in flags */
    const struct RProc *p = MRB_METHOD_PROC(m);
    if (p) {
      uint32_t bits = p->flags & MRB_PROC_CASPEC_MASK;
      if (bits) return aspec_params(mrb, mrb_proc_decompress_caspec(bits));
# ifdef MRB_PROC_NOARG
      if (MRB_PROC_NOARG_P(p)) return aspec_params(mrb, 0);
# endif
    }
    /* cfunc proc with no recorded caspec: fall through to mruby's own */
#endif
  }
  mrb_value msym = mrb_symbol_value(sym);
  mrb_value um = mrb_funcall_argv(mrb, recv, MRB_SYM(instance_method), 1, &msym);
  return mrb_funcall_argv(mrb, um, MRB_SYM(parameters), 0, NULL);
}

/* irep-derived return type, via the MrubyIrepReflect gem inside the VM. If the
 * gem isn't in this build, mrb_module_get raises -> RUN_OP's protect turns it
 * into nil: Stage 2 simply switches off, no crash (degrade-don't-crash). */
static mrb_value bd_return_type(mrb_state *mrb, void *ud);
static mrb_value bd_singleton_return_type(mrb_state *mrb, void *ud);

/* --- resolution helpers: pure; a raise inside is the gate, not a branch ----- */
static mrb_value resolve(mrb_state *mrb, req_t *q) {
  mrb_value name = mrb_str_new(mrb, q->cls, (mrb_int)q->clen);
  mrb_value k = mrb_funcall_argv(mrb, name, MRB_SYM(constantize), 0, NULL);
  ensure_module(mrb, k);
  return k;
}
static mrb_value singleton_of(mrb_state *mrb, mrb_value k) {
  return mrb_funcall_argv(mrb, k, MRB_SYM(singleton_class), 0, NULL);
}
static mrb_value unbound(mrb_state *mrb, mrb_value recv, req_t *q) {
  mrb_value msym = mrb_symbol_value(mrb_intern(mrb, q->meth, q->mlen));
  return mrb_funcall_argv(mrb, recv, MRB_SYM(instance_method), 1, &msym);
}

/* --- per-op bodies (the protect callbacks): each straight-line, no branches -- */
static mrb_value bd_ancestors(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, resolve(mrb, q), MRB_SYM(ancestors), 0, NULL));
  return mrb_nil_value();
}
static mrb_value bd_instance_methods(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value inc = mrb_bool_value(q->flag != 0);
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, resolve(mrb, q), MRB_SYM(instance_methods), 1, &inc));
  return mrb_nil_value();
}
static mrb_value bd_private_instance_methods(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value inc = mrb_bool_value(q->flag != 0);
  mrb_sym sym = mrb_intern_lit(mrb, "private_instance_methods");
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, resolve(mrb, q), sym, 1, &inc));
  return mrb_nil_value();
}
static mrb_value bd_constants(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, resolve(mrb, q), MRB_SYM(constants), 0, NULL));
  return mrb_nil_value();
}
static mrb_value bd_singleton_methods(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value inc = mrb_bool_value(q->flag != 0);
  mrb_value sk = singleton_of(mrb, resolve(mrb, q));
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, sk, MRB_SYM(instance_methods), 1, &inc));
  return mrb_nil_value();
}
static mrb_value bd_source_location(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value um = unbound(mrb, resolve(mrb, q), q);
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, um, MRB_SYM(source_location), 0, NULL));
  return mrb_nil_value();
}
static mrb_value bd_singleton_source_location(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value um = unbound(mrb, singleton_of(mrb, resolve(mrb, q)), q);
  q->out = vb_from_mrb(mrb, mrb_funcall_argv(mrb, um, MRB_SYM(source_location), 0, NULL));
  return mrb_nil_value();
}
static mrb_value bd_parameters(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  q->out = vb_from_mrb(mrb, params_for(mrb, resolve(mrb, q), q->meth, q->mlen));
  return mrb_nil_value();
}
static mrb_value bd_singleton_parameters(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  q->out = vb_from_mrb(mrb, params_for(mrb, singleton_of(mrb, resolve(mrb, q)), q->meth, q->mlen));
  return mrb_nil_value();
}
static mrb_value bd_cfunc_addr(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  q->out = vb_from_mrb(mrb, cfunc_addr_or_nil(mrb, resolve(mrb, q), q->meth, q->mlen));
  return mrb_nil_value();
}
static mrb_value bd_singleton_cfunc_addr(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  q->out = vb_from_mrb(mrb, cfunc_addr_or_nil(mrb, singleton_of(mrb, resolve(mrb, q)), q->meth, q->mlen));
  return mrb_nil_value();
}
static mrb_value bd_anchor(mrb_state *mrb, void *ud) {
  ((req_t *)ud)->out = vb_from_mrb(mrb, addr_to_num(mrb, (const void *)&mrb_open));
  return mrb_nil_value();
}

/* Fixed read at the hook (no host name): the compile-time facts the
 * mruby-platform gem baked into THIS VM -- [Platform::OS, Platform::Toolchain]
 * as Symbols. nil if the gem isn't in the build (mrb_module_get raises ->
 * RUN_OP's protect turns it into nil). The LSP picks its C symbolizer backend
 * from these instead of guessing the host environment. */
static mrb_value bd_platform(mrb_state *mrb, void *ud) {
  req_t *q = (req_t *)ud;
  struct RClass *m = mrb_module_get(mrb, "Platform");
  mrb_value pair[2];
  pair[0] = mrb_const_get(mrb, mrb_obj_value(m), MRB_SYM(OS));
  pair[1] = mrb_const_get(mrb, mrb_obj_value(m), MRB_SYM(Toolchain));
  q->out = vb_from_mrb(mrb, mrb_ary_new_from_values(mrb, 2, pair));
  return mrb_nil_value();
}

/* The protect dance, written once. `body` is always a literal callback name --
 * a direct symbol, never a stored or selected pointer -- so this is shared
 * boilerplate, not dispatch. The sole branch is protect's error flag; any raise
 * (bad name, missing method, non-class) becomes NULL -> nil downstream. */
static mrb_value bd_return_type(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value k = resolve(mrb, q);                      /* class/module (raises->nil) */
  struct RClass *ir = mrb_module_get(mrb, "MrubyIrepReflect"); /* raises->nil if gem absent */
  mrb_value sym = mrb_symbol_value(mrb_intern(mrb, q->meth, q->mlen));
  q->out = vb_from_mrb(mrb, mrb_funcall(mrb, mrb_obj_value(ir), "return_type", 2, k, sym));
  return mrb_nil_value();
}
static mrb_value bd_singleton_return_type(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value sk = singleton_of(mrb, resolve(mrb, q));
  struct RClass *ir = mrb_module_get(mrb, "MrubyIrepReflect");
  mrb_value sym = mrb_symbol_value(mrb_intern(mrb, q->meth, q->mlen));
  q->out = vb_from_mrb(mrb, mrb_funcall(mrb, mrb_obj_value(ir), "return_type", 2, sk, sym));
  return mrb_nil_value();
}

/* The class's mruby-native-ext-type schema: the gem's `net_schema` class method
 * returns { :@ivar => [Class, ...] } (a plain Hash) or nil. We funcall it and
 * hand the Hash straight out -- value_bridge serializes the Class values as
 * name tags, so host Ruby reads { :@ivar => ["Socket", ...] } and never sees a
 * live object. nil if the gem isn't compiled (the method is absent -> raise ->
 * RUN_OP protect -> nil) or the class declared nothing. Hardcoded selector,
 * no input dispatch, no logic -- a dumb reflection read like the others. */
static mrb_value bd_net_schema(mrb_state *mrb, void *ud) {
  req_t *q = ud;
  mrb_value k = resolve(mrb, q);                      /* class/module (raises->nil) */
  q->out = vb_from_mrb(mrb, mrb_funcall(mrb, k, "net_schema", 0));
  return mrb_nil_value();
}

#define RUN_OP(b, q, body) do {                          \
    mrb_gc_arena_restore((b)->mrb, (b)->arena_base);     \
    mrb_bool _err = FALSE;                               \
    mrb_value _exc = mrb_protect_error((b)->mrb, (body), &(q), &_err); \
    (b)->mrb->exc = NULL;                                \
    if (_err) {                                          \
      /* The op raised. mrb_protect_error's return value IS the exception; the \
       * value_bridge mruby producer serializes it to a VB_TAG_EXCEPTION_MRUBY \
       * tree (class, message, backtrace) -- raise-free, so this is safe on the \
       * post-protect path. The caller (Ruby) sees a ValueBridge::Tagged it can \
       * inspect, instead of an ambiguous nil. */ \
      vb_free((q).out);                                  \
      (q).out = vb_from_mrb((b)->mrb, _exc);             \
      return (q).out;                                    \
    }                                                    \
    return (q).out;                                      \
  } while (0)

/* --- entries: one per op. Ruby calls these directly; C never dispatches. ----*/
vb_value *mrb_bridge_ancestors(void *p, const char *cls, size_t clen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, NULL, 0, 0, NULL };
  RUN_OP(b, q, bd_ancestors);
}
vb_value *mrb_bridge_instance_methods(void *p, const char *cls, size_t clen, int inc) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, NULL, 0, inc, NULL };
  RUN_OP(b, q, bd_instance_methods);
}
vb_value *mrb_bridge_private_instance_methods(void *p, const char *cls, size_t clen, int inc) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, NULL, 0, inc, NULL };
  RUN_OP(b, q, bd_private_instance_methods);
}
vb_value *mrb_bridge_constants(void *p, const char *cls, size_t clen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, NULL, 0, 0, NULL };
  RUN_OP(b, q, bd_constants);
}
vb_value *mrb_bridge_net_schema(void *p, const char *cls, size_t clen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, NULL, 0, 0, NULL };
  RUN_OP(b, q, bd_net_schema);
}
vb_value *mrb_bridge_singleton_methods(void *p, const char *cls, size_t clen, int inc) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, NULL, 0, inc, NULL };
  RUN_OP(b, q, bd_singleton_methods);
}
vb_value *mrb_bridge_anchor_addr(void *p) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { NULL, 0, NULL, 0, 0, NULL };
  RUN_OP(b, q, bd_anchor);
}

vb_value *mrb_bridge_platform(void *p) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { NULL, 0, NULL, 0, 0, NULL };
  RUN_OP(b, q, bd_platform);
}
vb_value *mrb_bridge_source_location(void *p, const char *cls, size_t clen,
                                     const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_source_location);
}
vb_value *mrb_bridge_singleton_source_location(void *p, const char *cls, size_t clen,
                                               const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_singleton_source_location);
}
vb_value *mrb_bridge_return_type(void *p, const char *cls, size_t clen,
                                 const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_return_type);
}
vb_value *mrb_bridge_singleton_return_type(void *p, const char *cls, size_t clen,
                                           const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_singleton_return_type);
}
vb_value *mrb_bridge_parameters(void *p, const char *cls, size_t clen,
                                const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_parameters);
}
vb_value *mrb_bridge_singleton_parameters(void *p, const char *cls, size_t clen,
                                          const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_singleton_parameters);
}
vb_value *mrb_bridge_cfunc_addr(void *p, const char *cls, size_t clen,
                                const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_cfunc_addr);
}
vb_value *mrb_bridge_singleton_cfunc_addr(void *p, const char *cls, size_t clen,
                                          const char *meth, size_t mlen) {
  bridge_t *b = (bridge_t *)p;
  req_t q = { cls, clen, meth, mlen, 0, NULL };
  RUN_OP(b, q, bd_singleton_cfunc_addr);
}
