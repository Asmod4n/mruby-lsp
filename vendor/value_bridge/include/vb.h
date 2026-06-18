/* value_bridge -- neutral tagged value exchanged between Ruby runtimes.
 *
 * One representation, three runtimes. Each runtime ships a PRODUCER (native ->
 * vb_value) and a CONSUMER (vb_value -> native). See README for the full
 * contract; the lifetime rules are restated at the bottom of this header.
 */
#ifndef VALUE_BRIDGE_H
#define VALUE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Tag set tracks mruby's value-level primitives plus the cross-runtime escape
 * hatch. Guarded mruby types (bigint/rational/complex) and gem types (time) are
 * produced only where the source runtime has them; a consumer that can't build
 * one still receives a faithful neutral form (e.g. bigint as a base-10 string).
 */
typedef enum {
  VB_NIL = 0,
  VB_TRUE,
  VB_FALSE,
  VB_INT,       /* as.i  : int64 (fits) */
  VB_FLOAT,     /* as.f  : double */
  VB_SYMBOL,    /* as.s  : symbol name, UTF-8 */
  VB_UTF8,      /* as.s  : valid UTF-8 text */
  VB_BYTES,     /* as.s  : opaque bytes, no encoding promise */
  VB_BIGINT,    /* as.s  : base-10 digits, e.g. "-1208925819614629174706176" */
  VB_ARRAY,     /* as.seq: items[count] */
  VB_HASH,      /* as.seq: items[count], count even; pair i = (items[2i],items[2i+1]) */
  VB_RANGE,     /* as.seq: items[2] = {begin,end}; aux = exclusive (0/1) */
  VB_TAGGED,    /* as.tagged: a value with a per-tag codec (Class, Rational, ...) */

  VB_TAG_MAX    /* sentinel: one past the last value tag. NOT a tag. The enum
                 * starts at 0 (VB_NIL), so the valid tags are [0, VB_TAG_MAX)
                 * and any iterator/generator walks that range without a
                 * hardcoded count. Keep this last. */
} vb_tag;

/* Well-known tag ids. The registry is CLOSED: these are exactly the tags
 * value_bridge ships. There is no public API to define new ones -- the bridge
 * converts values between runtimes and the tag set is an internal mechanic, not
 * an extension point. Mirrors the CBOR tag model (an id plus a payload, with a
 * per-tag encode/decode), minus any private-use range. */
enum {
  VB_TAG_CLASS    = 1,   /* payload: qualified name (utf8) */
  VB_TAG_MODULE   = 2,   /* payload: qualified name (utf8) */
  VB_TAG_RATIONAL = 3,   /* payload: [numerator, denominator] */
  VB_TAG_COMPLEX  = 4,   /* payload: [real, imag] */
  VB_TAG_TIME     = 5,   /* payload: [sec, nsec, utc] -- absolute epoch sec +
                          * subsecond nsec + a UTC-or-local flag (bool). mruby
                          * has no zones/offsets, only UTC or local, so that is
                          * all the bridge carries. */
  VB_TAG_SET      = 6,   /* payload: [elements...] */
  VB_TAG_PROC     = 7,   /* payload: dumped mruby irep (bytes); mruby-origin only */

  /* Exceptions carry their ORIGIN runtime in the tag id: an exception is
   * inseparable from its runtime's class hierarchy AND backtrace format, so an
   * mruby/CRuby/JRuby exception are distinct even when same-named. One tag per
   * runtime lets the consumer resolve the class against the right hierarchy and
   * read frames in the right terms. Payload is uniform:
   *   [ class_name(utf8), message(utf8), backtrace(array of utf8 frames) ]
   * Only the mruby PRODUCER is implemented today (reflection runs in an mruby
   * VM); CRUBY/JRUBY ids are reserved so the contract is complete and a future
   * producer needs no renumber. Unknown ids still survive as a generic Tagged. */
  VB_TAG_EXCEPTION_MRUBY = 8,
  VB_TAG_EXCEPTION_CRUBY = 9,
  VB_TAG_EXCEPTION_JRUBY = 10,

  VB_TAG_MAX_ID         /* sentinel: one past the last id (= 11). Valid ids are
                         * [1, VB_TAG_MAX_ID). An id outside that range on decode
                         * is a foreign/malformed tree, never a user tag. Last. */
};

typedef struct { const char *ptr; size_t len; } vb_span;

typedef struct vb_value vb_value;
struct vb_value {
  vb_tag  tag;
  int     aux;        /* VB_RANGE: exclusive flag. unused otherwise. */
  union {
    int64_t i;
    double  f;
    vb_span s;
    struct { vb_value *items; size_t count; } seq;   /* ARRAY/HASH/RANGE */
    struct { uint32_t id; vb_value *payload; } tagged;
  } as;
};

/* --- structural allocation (byte spans are filled in by the producer) ------ */

vb_value *vb_new(void);                                      /* one VB_NIL node */
vb_value *vb_new_seq(vb_tag tag, size_t count);              /* owns items[count] */
vb_value *vb_new_tagged(uint32_t id, vb_value *payload);     /* owns payload */
void      vb_free(vb_value *v);            /* frees nodes + items[] + payload; not spans */

int         vb_is_utf8(const char *ptr, size_t len);

/* --- enum name lookup (one table, shared by every leg) ----------------------
 * Human-readable names for the tags, as string literals baked into the
 * library's read-only data -- never heap-allocated. The names live exactly
 * once, in C (src/vb_names.c), so no runtime re-lists them and no parser/regex
 * is needed anywhere: a consumer that receives tag id 7 can show "VB_TAG_PROC".
 * Returns a borrowed pointer to a string literal, or NULL for an unknown id.
 * The pointer is valid for the lifetime of the library; do not free it. */
const char *vb_tag_name(int tag);        /* vb_tag value:  6 -> "VB_UTF8"      */
const char *vb_tag_id_name(uint32_t id); /* VB_TAGGED id:  7 -> "VB_TAG_PROC"  */

#ifdef __cplusplus
}
#endif

/* --- ownership / lifetime ---------------------------------------------------
 * A vb_value tree is valid for ONE producer->consumer exchange. Byte spans
 * (vb_span: UTF8/BYTES/SYMBOL/BIGINT text) are BORROWED from
 * memory the producer keeps alive for that window; the consumer must
 * copy/materialize before returning control. vb_free() frees the structural
 * nodes and the items[] block of any sequence tag (ARRAY/HASH/RANGE); it never
 * frees spans. */
#endif /* VALUE_BRIDGE_H */
