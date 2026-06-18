/* CRuby leg -- VALUE <-> vb_value. CRuby macros live ONLY here.
 *
 * Floor (mrb_open_core types) bridges directly. Beyond the floor, a value is
 * either a registered TAG (some VM can byte-encode/decode it) or it cannot be
 * represented at all -- in which case encode RAISES. There is no lossy opaque
 * wrapper. Tags this VM can't natively rebuild surface as ValueBridge::Tagged,
 * which re-encodes intact (faithful pass-through), since some VM authored it.
 */
#include "vb_cruby.h"          /* ruby.h + vb.h */
#include <ruby/encoding.h>
#include <stdlib.h>
#include <stdint.h>

static vb_value *cruby_produce(VALUE v);

static VALUE vb_mod(void)     { return rb_const_get(rb_cObject, rb_intern("ValueBridge")); }
static VALUE tagged_class(void){ return rb_const_get(vb_mod(), rb_intern("Tagged")); }

static int cruby_str_span(VALUE v, vb_span *out) {
  if (!RB_TYPE_P(v, T_STRING)) { out->ptr = NULL; out->len = 0; return 0; }
  out->ptr = RSTRING_PTR(v); out->len = (size_t)RSTRING_LEN(v); return 1;
}
static void put(vb_value *slot, VALUE child) {
  vb_value *c = cruby_produce(child);
  if (c) { *slot = *c; free(c); }
}
struct hash_ctx { vb_value *items; size_t i; };
static int hash_cb(VALUE k, VALUE val, VALUE arg) {
  struct hash_ctx *c = (struct hash_ctx *)(uintptr_t)arg;
  put(&c->items[c->i++], k); put(&c->items[c->i++], val);
  return ST_CONTINUE;
}

/* TAG encode: a class/module becomes its qualified name as the payload. */
static vb_value *tag_named(VALUE v, uint32_t id) {
  VALUE nm = rb_class_name(v);                 /* qualified name, or nil if anon */
  if (NIL_P(nm)) nm = rb_obj_as_string(v);
  vb_value *p = vb_new();
  if (!p) return NULL;
  p->tag = VB_UTF8; cruby_str_span(nm, &p->as.s);
  return vb_new_tagged(id, p);
}
/* re-encode a carrier so an unknown tag round-trips */
static vb_value *reencode_tagged(VALUE v) {
  uint32_t id = (uint32_t)NUM2ULONG(rb_funcall(v, rb_intern("tag"), 0));
  vb_value *p = cruby_produce(rb_funcall(v, rb_intern("payload"), 0));
  return vb_new_tagged(id, p);
}

/* TIME encode: [sec, nsec, utc] -- absolute instant + UTC-or-local flag. CRuby
 * has zones/offsets, but the bridge only carries what mruby can model. */
static vb_value *tag_time(VALUE v) {
  long long sec  = NUM2LL(rb_funcall(v, rb_intern("to_i"), 0));
  long long nsec = NUM2LL(rb_funcall(v, rb_intern("nsec"), 0));
  int utc = RTEST(rb_funcall(v, rb_intern("utc?"), 0));
  vb_value *a = vb_new_seq(VB_ARRAY, 3);
  if (!a) return NULL;
  a->as.seq.items[0].tag = VB_INT; a->as.seq.items[0].as.i = (int64_t)sec;
  a->as.seq.items[1].tag = VB_INT; a->as.seq.items[1].as.i = (int64_t)nsec;
  a->as.seq.items[2].tag = utc ? VB_TRUE : VB_FALSE;
  return vb_new_tagged(VB_TAG_TIME, a);
}
static VALUE consume_time(const vb_value *a) {
  long long sec = 0, nsec = 0; int utc = 0;
  if (a && a->tag == VB_ARRAY && a->as.seq.count >= 3) {
    const vb_value *e = a->as.seq.items;
    if (e[0].tag == VB_INT) sec  = (long long)e[0].as.i;
    if (e[1].tag == VB_INT) nsec = (long long)e[1].as.i;
    utc = (e[2].tag == VB_TRUE);
  }
  VALUE t = rb_funcall(rb_cTime, rb_intern("at"), 3,
                       LL2NUM(sec), LL2NUM(nsec), ID2SYM(rb_intern("nanosecond")));
  if (utc) t = rb_funcall(t, rb_intern("utc"), 0);
  return t;
}

static vb_value *cruby_produce(VALUE v) {
  vb_value *out = vb_new();
  if (!out) return NULL;
  switch (TYPE(v)) {
    case T_NIL:    out->tag = VB_NIL;   return out;
    case T_TRUE:   out->tag = VB_TRUE;  return out;
    case T_FALSE:  out->tag = VB_FALSE; return out;
    case T_FIXNUM: out->tag = VB_INT;   out->as.i = (int64_t)NUM2LL(v); return out;
    case T_FLOAT:  out->tag = VB_FLOAT; out->as.f = NUM2DBL(v); return out;
    case T_SYMBOL: { VALUE s = rb_sym2str(v); out->tag = VB_SYMBOL; cruby_str_span(s, &out->as.s); return out; }
    case T_STRING: {
      vb_span sp; cruby_str_span(v, &sp);
      rb_encoding *e = rb_enc_get(v);
      int u = (e == rb_utf8_encoding() || e == rb_usascii_encoding());
      out->tag = (u && vb_is_utf8(sp.ptr, sp.len)) ? VB_UTF8 : VB_BYTES; out->as.s = sp; return out;
    }
    case T_BIGNUM: { VALUE s = rb_big2str(v, 10); out->tag = VB_BIGINT; cruby_str_span(s, &out->as.s); return out; }
    case T_ARRAY: {
      if (!RB_TYPE_P(v, T_ARRAY)) { out->tag = VB_NIL; return out; }
      long n = RARRAY_LEN(v);
      vb_value *a = vb_new_seq(VB_ARRAY, (size_t)n);
      if (a) for (long k = 0; k < n; k++) put(&a->as.seq.items[k], rb_ary_entry(v, k));
      vb_free(out); return a ? a : vb_new();
    }
    case T_HASH: {
      if (!RB_TYPE_P(v, T_HASH)) { out->tag = VB_NIL; return out; }
      long pairs = RHASH_SIZE(v);
      vb_value *h = vb_new_seq(VB_HASH, (size_t)pairs * 2);
      if (h) { struct hash_ctx c = { h->as.seq.items, 0 }; rb_hash_foreach(v, hash_cb, (VALUE)(uintptr_t)&c); }
      vb_free(out); return h ? h : vb_new();
    }
    default: {
      VALUE beg, end; int excl;
      if (rb_obj_is_kind_of(v, rb_cRange) && rb_range_values(v, &beg, &end, &excl)) {
        vb_value *r = vb_new_seq(VB_RANGE, 2);
        if (!r) { vb_free(out); return vb_new(); }
        r->aux = excl ? 1 : 0; put(&r->as.seq.items[0], beg); put(&r->as.seq.items[1], end);
        vb_free(out); return r;
      }
      if (rb_obj_is_kind_of(v, rb_cTime)) { vb_free(out); return tag_time(v); }
      if (RB_TYPE_P(v, T_CLASS))  { vb_free(out); return tag_named(v, VB_TAG_CLASS); }
      if (RB_TYPE_P(v, T_MODULE)) { vb_free(out); return tag_named(v, VB_TAG_MODULE); }
      if (rb_obj_is_kind_of(v, tagged_class())) { vb_free(out); return reencode_tagged(v); }
      vb_free(out);
      rb_raise(rb_eTypeError,
               "value_bridge: cannot represent %s (no byte representation in any runtime)",
               rb_obj_classname(v));
    }
  }
}

static VALUE str_utf8(vb_span s)  { return rb_enc_str_new(s.ptr, (long)s.len, rb_utf8_encoding()); }
static VALUE str_bytes(vb_span s) { return rb_enc_str_new(s.ptr, (long)s.len, rb_ascii8bit_encoding()); }

static VALUE cruby_consume(const vb_value *v) {
  switch (v->tag) {
    case VB_NIL:   return Qnil;
    case VB_TRUE:  return Qtrue;
    case VB_FALSE: return Qfalse;
    case VB_INT:   return LL2NUM(v->as.i);
    case VB_FLOAT: return DBL2NUM(v->as.f);
    case VB_SYMBOL:return rb_str_intern(str_utf8(v->as.s));
    case VB_UTF8:  return str_utf8(v->as.s);
    case VB_BYTES: return str_bytes(v->as.s);
    case VB_BIGINT:return rb_str_to_inum(str_utf8(v->as.s), 10, TRUE);
    case VB_ARRAY: {
      VALUE a = rb_ary_new_capa((long)v->as.seq.count);
      for (size_t k = 0; k < v->as.seq.count; k++) rb_ary_push(a, cruby_consume(&v->as.seq.items[k]));
      return a;
    }
    case VB_HASH: {
      VALUE h = rb_hash_new();
      for (size_t k = 0; k + 1 < v->as.seq.count; k += 2)
        rb_hash_aset(h, cruby_consume(&v->as.seq.items[k]), cruby_consume(&v->as.seq.items[k + 1]));
      return h;
    }
    case VB_RANGE: {
      VALUE b = v->as.seq.count > 0 ? cruby_consume(&v->as.seq.items[0]) : Qnil;
      VALUE e = v->as.seq.count > 1 ? cruby_consume(&v->as.seq.items[1]) : Qnil;
      return rb_range_new(b, e, v->aux ? 1 : 0);
    }
    case VB_TAGGED: {
      /* Tags this VM can rebuild decode natively (Time); the rest surface as a
       * carrier that re-encodes intact (Class/Module identity is meaningless
       * across runtimes). */
      if (v->as.tagged.id == VB_TAG_TIME) return consume_time(v->as.tagged.payload);
      VALUE payload = cruby_consume(v->as.tagged.payload);
      VALUE args[2] = { ULONG2NUM(v->as.tagged.id), payload };
      return rb_funcallv(tagged_class(), rb_intern("new"), 2, args);
    }
    default: return Qnil;
  }
}

vb_value *vb_from_value(VALUE v)        { return cruby_produce(v); }
VALUE     vb_to_value(const vb_value *v){ return cruby_consume(v); }
