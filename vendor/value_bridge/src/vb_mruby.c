/* mruby leg -- mrb_value <-> vb_value. mruby macros live ONLY here.
 *
 * Floor (mrb_open_core types) bridges directly. Class/Module/SClass become
 * NAME tags. A value that is neither floor nor a known tag (Proc, plain object,
 * an OS thread, ...) RAISES -- there is no lossy wrapper. Unknown tags surface
 * as ValueBridge::Tagged and re-encode intact. Container walks freeze the source
 * during iteration. Strict typing: *_p before every typed accessor.
 */
#include "vb_mruby.h"          /* mruby.h + vb.h */
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/range.h>
#include <mruby/class.h>
#include <time.h>
#include <mruby/variable.h>
#include <mruby/internal.h>    /* mrb_bint_to_s / mrb_bint_new_str */
#include <mruby/proc.h>        /* mrb_proc_ptr / MRB_PROC_CFUNC_P */
#include <mruby/error.h>       /* mrb_exc_ptr, struct RException; mrb_exc_backtrace via internal.h */
#if defined(__has_include)
#  if __has_include(<mruby/proc_irep_ext.h>)
#    include <mruby/proc_irep_ext.h>   /* mrb_proc_to_irep / mrb_proc_from_irep */
#    define VB_HAVE_PROC_IREP 1
#  endif
#  if __has_include(<mruby/time.h>)
#    include <mruby/time.h>          /* mrb_time_at / mrb_time_get_tm (the only two) */
#    define VB_HAVE_TIME 1
#  endif
#endif
#include <stdlib.h>
#include <string.h>

static vb_value *mruby_produce(mrb_state *mrb, mrb_value v);

static struct RClass *tagged_class(mrb_state *mrb) {
  return mrb_class_get_under(mrb, mrb_module_get(mrb, "__ValueBridge"), "Tagged");
}
static int mruby_str_span(mrb_value v, vb_span *out) {
  if (!mrb_string_p(v)) { out->ptr = NULL; out->len = 0; return 0; }
  out->ptr = RSTRING_PTR(v); out->len = (size_t)RSTRING_LEN(v); return 1;
}
static void put(mrb_state *mrb, vb_value *slot, mrb_value child) {
  vb_value *c = mruby_produce(mrb, child);
  if (c) { *slot = *c; free(c); }
}
struct hash_ctx { mrb_state *mrb; vb_value *items; size_t i; };
static int hash_cb(mrb_state *mrb, mrb_value k, mrb_value val, void *p) {
  struct hash_ctx *c = (struct hash_ctx *)p;
  put(mrb, &c->items[c->i++], k); put(mrb, &c->items[c->i++], val);
  return 0;
}

/* TAG encode: a class/module's qualified name (to_s) is the payload. */
static vb_value *tag_named(mrb_state *mrb, mrb_value v, uint32_t id) {
  mrb_value nm = mrb_funcall(mrb, v, "to_s", 0);   /* Class#to_s -> name */
  vb_value *p = vb_new();
  if (!p) return NULL;
  p->tag = VB_UTF8; mruby_str_span(nm, &p->as.s);
  return vb_new_tagged(id, p);
}
static vb_value *reencode_tagged(mrb_state *mrb, mrb_value v) {
  mrb_value tid = mrb_funcall(mrb, v, "tag", 0);
  uint32_t id = mrb_integer_p(tid) ? (uint32_t)mrb_integer(tid) : 0;
  vb_value *p = mruby_produce(mrb, mrb_funcall(mrb, v, "payload", 0));
  return vb_new_tagged(id, p);
}

/* Fill a vb_value string slot from an mruby String, UTF8 vs BYTES by content,
 * matching the MRB_TT_STRING case. Empty string for a NULL/non-string input. */
static void exc_str_slot(vb_value *slot, mrb_value s) {
  if (mrb_string_p(s)) {
    vb_span sp; mruby_str_span(s, &sp);
    slot->tag = vb_is_utf8(sp.ptr, sp.len) ? VB_UTF8 : VB_BYTES;
    slot->as.s = sp;
  } else {
    slot->tag = VB_UTF8; slot->as.s.ptr = ""; slot->as.s.len = 0;
  }
}

/* Exception -> VB_TAG_EXCEPTION_MRUBY with payload [class, message, [frames]].
 * ALL reads are pure C -- NO funcall -- so this is raise-free, which is what
 * lets RUN_OP call it from its already-returned protect-error path without
 * re-faulting:
 *   class -> mrb_obj_classname (borrowed const char*, lives with the class)
 *   mesg  -> RException.mesg struct field (RString or NULL)
 *   bt    -> mrb_exc_backtrace (internal.h): nil | [String]; it unpacks the
 *            packed form and caches it back on the exception internally.
 * The message/frame spans are BORROWED from these mruby strings; they stay
 * valid until the consumer copies them out, same one-exchange contract as every
 * other producer path (the strings live on the arena, restored only on the next
 * op's entry, after the CRuby side has materialized this tree). */
static vb_value *tag_exception(mrb_state *mrb, mrb_value exc, uint32_t id) {
  vb_value *pay = vb_new_seq(VB_ARRAY, 3);
  if (!pay) return NULL;

  /* [0] class name */
  const char *cn = mrb_obj_classname(mrb, exc);
  if (cn) {
    pay->as.seq.items[0].tag = vb_is_utf8(cn, strlen(cn)) ? VB_UTF8 : VB_BYTES;
    pay->as.seq.items[0].as.s.ptr = cn;
    pay->as.seq.items[0].as.s.len = strlen(cn);
  } else {
    pay->as.seq.items[0].tag = VB_UTF8;
    pay->as.seq.items[0].as.s.ptr = ""; pay->as.seq.items[0].as.s.len = 0;
  }

  /* [1] message: mrb_exc_mesg_get (internal.h) — proper accessor, no struct
   * poke; returns the message mrb_value (or nil). */
  exc_str_slot(&pay->as.seq.items[1], mrb_exc_mesg_get(mrb, mrb_exc_ptr(exc)));

  /* [2] backtrace: nil -> [], [String] -> array of frames (same put() walk
   * the MRB_TT_ARRAY case uses, so frozen-guard semantics aren't needed: this
   * is a fresh array mruby just built, not a user value being mutated). */
  mrb_value bt = mrb_exc_backtrace(mrb, exc);
  mrb_int bn = mrb_array_p(bt) ? RARRAY_LEN(bt) : 0;
  vb_value *frames = vb_new_seq(VB_ARRAY, (size_t)bn);
  if (frames) {
    for (mrb_int k = 0; k < bn; k++)
      put(mrb, &frames->as.seq.items[k], mrb_ary_ref(mrb, bt, k));
    pay->as.seq.items[2] = *frames;
    free(frames);
  } else {
    pay->as.seq.items[2].tag = VB_ARRAY;
    pay->as.seq.items[2].as.seq.items = NULL;
    pay->as.seq.items[2].as.seq.count = 0;
  }

  return vb_new_tagged(id, pay);
}

#ifdef VB_HAVE_TIME
/* portable civil(Y,M,D) -> days since 1970-01-01 (no libc TZ dependency) */
static long long vb_days_from_civil(int y, int m, int d) {
  y -= (m <= 2);
  long long era = (long long)((y >= 0 ? y : y - 399) / 400);
  int yoe = (int)(y - era * 400);
  int doy = (153 * ((m > 2) ? (m - 3) : (m + 9)) + 2) / 5 + d - 1;
  int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097LL + doe - 719468;
}
/* TIME encode via the public mruby-time C API. mrb_time_get_tm gives a struct tm
 * (calendar fields in the time's zone) -- no subsecond, so mruby-origin Time is
 * second-precision. utc-or-local from tm_gmtoff (0 => UTC mode). */
static vb_value *tag_time(mrb_state *mrb, mrb_value v) {
  struct tm *tm = mrb_time_get_tm(mrb, v);
  long long wall = vb_days_from_civil(tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday) * 86400LL
                 + (long long)tm->tm_hour * 3600 + (long long)tm->tm_min * 60 + tm->tm_sec;
  long off = 0; int utc;
#if defined(__GLIBC__) || defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__CYGWIN__)
  off = (long)tm->tm_gmtoff;     /* seconds east of UTC; 0 in UTC mode */
  utc = (off == 0);
#else
  utc = 1;                       /* no tm_gmtoff (e.g. MSVC): treat as UTC */
#endif
  long long sec = wall - off;    /* wall clock - zone offset = true UTC epoch */
  vb_value *a = vb_new_seq(VB_ARRAY, 3);
  if (!a) return NULL;
  a->as.seq.items[0].tag = VB_INT; a->as.seq.items[0].as.i = (int64_t)sec;
  a->as.seq.items[1].tag = VB_INT; a->as.seq.items[1].as.i = 0;  /* struct tm: no subsecond */
  a->as.seq.items[2].tag = utc ? VB_TRUE : VB_FALSE;
  return vb_new_tagged(VB_TAG_TIME, a);
}
#endif

static vb_value *mruby_produce(mrb_state *mrb, mrb_value v) {
  vb_value *out = vb_new();
  if (!out) return NULL;
  switch (mrb_type(v)) {
    case MRB_TT_FALSE: out->tag = mrb_nil_p(v) ? VB_NIL : VB_FALSE; return out;
    case MRB_TT_TRUE:  out->tag = VB_TRUE; return out;
    case MRB_TT_INTEGER:
      if (!mrb_integer_p(v)) { out->tag = VB_NIL; return out; }
      out->tag = VB_INT; out->as.i = (int64_t)mrb_integer(v); return out;
#ifndef MRB_NO_FLOAT
    case MRB_TT_FLOAT:
      if (!mrb_float_p(v)) { out->tag = VB_NIL; return out; }
      out->tag = VB_FLOAT; out->as.f = (double)mrb_float(v); return out;
#endif
    case MRB_TT_SYMBOL: { mrb_value s = mrb_sym2str(mrb, mrb_symbol(v)); out->tag = VB_SYMBOL; mruby_str_span(s, &out->as.s); return out; }
    case MRB_TT_STRING: {
      vb_span sp; mruby_str_span(v, &sp);
      out->tag = vb_is_utf8(sp.ptr, sp.len) ? VB_UTF8 : VB_BYTES; out->as.s = sp; return out;
    }
#ifdef MRB_USE_BIGINT
    case MRB_TT_BIGINT: { mrb_value s = mrb_bint_to_s(mrb, v, 10); out->tag = VB_BIGINT; mruby_str_span(s, &out->as.s); return out; }
#endif
    case MRB_TT_ARRAY: {
      if (!mrb_array_p(v)) { out->tag = VB_NIL; return out; }
      struct RBasic *b = mrb_basic_ptr(v); unsigned wf = b->frozen; b->frozen = 1;
      mrb_int n = RARRAY_LEN(v);
      vb_value *a = vb_new_seq(VB_ARRAY, (size_t)n);
      if (a) for (mrb_int k = 0; k < n; k++) put(mrb, &a->as.seq.items[k], mrb_ary_ref(mrb, v, k));
      b->frozen = wf; vb_free(out); return a ? a : vb_new();
    }
    case MRB_TT_HASH: {
      if (!mrb_hash_p(v)) { out->tag = VB_NIL; return out; }
      struct RBasic *b = mrb_basic_ptr(v); unsigned wf = b->frozen; b->frozen = 1;
      mrb_int pairs = mrb_hash_size(mrb, v);
      vb_value *h = vb_new_seq(VB_HASH, (size_t)pairs * 2);
      if (h) { struct hash_ctx c = { mrb, h->as.seq.items, 0 }; mrb_hash_foreach(mrb, mrb_hash_ptr(v), hash_cb, &c); }
      b->frozen = wf; vb_free(out); return h ? h : vb_new();
    }
    case MRB_TT_RANGE: {
      vb_value *r = vb_new_seq(VB_RANGE, 2);
      if (!r) { vb_free(out); return vb_new(); }
      r->aux = mrb_range_excl_p(mrb, v) ? 1 : 0;
      put(mrb, &r->as.seq.items[0], mrb_range_beg(mrb, v));
      put(mrb, &r->as.seq.items[1], mrb_range_end(mrb, v));
      vb_free(out); return r;
    }
    case MRB_TT_PROC: {
      vb_free(out);                       /* scratch node not needed either way */
#ifdef VB_HAVE_PROC_IREP
      struct RProc *p = mrb_proc_ptr(v);
      if (!MRB_PROC_CFUNC_P(p)) {          /* C procs have no irep -> unrepresentable */
        mrb_value bin = mrb_proc_to_irep(mrb, p);   /* irep bytes; raises on failure */
        vb_value *pay = vb_new();
        if (!pay) return NULL;
        pay->tag = VB_BYTES; mruby_str_span(bin, &pay->as.s);
        return vb_new_tagged(VB_TAG_PROC, pay);
      }
#endif
      mrb_raisef(mrb, E_TYPE_ERROR,
                 "value_bridge: cannot represent %t (no byte representation in any runtime)", v);
      return NULL;
    }
    case MRB_TT_CLASS:  vb_free(out); return tag_named(mrb, v, VB_TAG_CLASS);
    case MRB_TT_MODULE: vb_free(out); return tag_named(mrb, v, VB_TAG_MODULE);
    case MRB_TT_SCLASS: vb_free(out); return tag_named(mrb, v, VB_TAG_CLASS);
    case MRB_TT_EXCEPTION: vb_free(out); return tag_exception(mrb, v, VB_TAG_EXCEPTION_MRUBY);
    default:
#ifdef VB_HAVE_TIME
      if (mrb_class_defined(mrb, "Time") &&
          mrb_obj_is_kind_of(mrb, v, mrb_class_get(mrb, "Time"))) { vb_free(out); return tag_time(mrb, v); }
#endif
      if (mrb_obj_is_kind_of(mrb, v, tagged_class(mrb))) { vb_free(out); return reencode_tagged(mrb, v); }
      vb_free(out);
      mrb_raisef(mrb, E_TYPE_ERROR,
                 "value_bridge: cannot represent %t (no byte representation in any runtime)", v);
      return NULL; /* unreachable */
  }
}

static mrb_value mruby_consume(mrb_state *mrb, const vb_value *v) {
  switch (v->tag) {
    case VB_NIL:   return mrb_nil_value();
    case VB_TRUE:  return mrb_true_value();
    case VB_FALSE: return mrb_false_value();
    case VB_INT:   return mrb_int_value(mrb, (mrb_int)v->as.i);
#ifndef MRB_NO_FLOAT
    case VB_FLOAT: return mrb_float_value(mrb, (mrb_float)v->as.f);
#endif
    case VB_SYMBOL: return mrb_symbol_value(mrb_intern(mrb, v->as.s.ptr, v->as.s.len));
    case VB_UTF8:
    case VB_BYTES:  return mrb_str_new(mrb, v->as.s.ptr, (mrb_int)v->as.s.len);
    case VB_BIGINT:
#ifdef MRB_USE_BIGINT
      return mrb_bint_new_str(mrb, v->as.s.ptr, (mrb_int)v->as.s.len, 10);
#else
      return mrb_str_new(mrb, v->as.s.ptr, (mrb_int)v->as.s.len);
#endif
    case VB_ARRAY: {
      mrb_value a = mrb_ary_new_capa(mrb, (mrb_int)v->as.seq.count);
      for (size_t k = 0; k < v->as.seq.count; k++) mrb_ary_push(mrb, a, mruby_consume(mrb, &v->as.seq.items[k]));
      return a;
    }
    case VB_HASH: {
      mrb_value h = mrb_hash_new_capa(mrb, (mrb_int)(v->as.seq.count / 2));
      for (size_t k = 0; k + 1 < v->as.seq.count; k += 2)
        mrb_hash_set(mrb, h, mruby_consume(mrb, &v->as.seq.items[k]), mruby_consume(mrb, &v->as.seq.items[k + 1]));
      return h;
    }
    case VB_RANGE: {
      mrb_value b = v->as.seq.count > 0 ? mruby_consume(mrb, &v->as.seq.items[0]) : mrb_nil_value();
      mrb_value e = v->as.seq.count > 1 ? mruby_consume(mrb, &v->as.seq.items[1]) : mrb_nil_value();
      return mrb_range_new(mrb, b, e, v->aux ? TRUE : FALSE);
    }
    case VB_TAGGED: {
      const vb_value *pl = v->as.tagged.payload;
#ifdef VB_HAVE_PROC_IREP
      if (v->as.tagged.id == VB_TAG_PROC && pl && (pl->tag == VB_BYTES || pl->tag == VB_UTF8))
        return mrb_proc_from_irep(mrb, pl->as.s.ptr, pl->as.s.len);  /* validates header, raises on bad */
#endif
#ifdef VB_HAVE_TIME
      if (v->as.tagged.id == VB_TAG_TIME && mrb_class_defined(mrb, "Time")) {
        long long sec = 0, nsec = 0; int utc = 0;
        if (pl && pl->tag == VB_ARRAY && pl->as.seq.count >= 3) {
          const vb_value *e = pl->as.seq.items;
          if (e[0].tag == VB_INT) sec  = (long long)e[0].as.i;
          if (e[1].tag == VB_INT) nsec = (long long)e[1].as.i;
          utc = (e[2].tag == VB_TRUE);
        }
        return mrb_time_at(mrb, (time_t)sec, (time_t)(nsec / 1000),
                           utc ? MRB_TIMEZONE_UTC : MRB_TIMEZONE_LOCAL);
      }
#endif
      mrb_value payload = mruby_consume(mrb, v->as.tagged.payload);
      mrb_value args[2] = { mrb_int_value(mrb, (mrb_int)v->as.tagged.id), payload };
      return mrb_obj_new(mrb, tagged_class(mrb), 2, args);
    }
    default: return mrb_nil_value();
  }
}

vb_value  *vb_from_mrb(mrb_state *mrb, mrb_value v)     { return mruby_produce(mrb, v); }
mrb_value  vb_to_mrb(mrb_state *mrb, const vb_value *v) { return mruby_consume(mrb, v); }
