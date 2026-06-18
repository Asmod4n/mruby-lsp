/* value_bridge core -- runtime-agnostic helpers. No Ruby/mruby headers. */
#include "vb.h"
#include <stdlib.h>

vb_value *vb_new(void) {
  vb_value *v = (vb_value *)calloc(1, sizeof *v);
  if (v) v->tag = VB_NIL;
  return v;
}

static int is_seq(vb_tag t) { return t == VB_ARRAY || t == VB_HASH || t == VB_RANGE; }

vb_value *vb_new_tagged(uint32_t id, vb_value *payload) {
  vb_value *v = vb_new();
  if (!v) { vb_free(payload); return NULL; }
  v->tag = VB_TAGGED; v->as.tagged.id = id; v->as.tagged.payload = payload;
  return v;
}

vb_value *vb_new_seq(vb_tag tag, size_t count) {
  vb_value *v = vb_new();
  if (!v) return NULL;
  v->tag = tag;
  v->as.seq.count = count;
  v->as.seq.items = count ? (vb_value *)calloc(count, sizeof(vb_value)) : NULL;
  if (count && !v->as.seq.items) { free(v); return NULL; }
  return v;
}

/* Free items[] blocks owned by sequence nodes, recursively. Interior element
 * nodes live inside a calloc'd block and are never individually freed -- only
 * the blocks, and (in vb_free) the top node. Spans are borrowed, never freed. */
static void free_contents(vb_value *v) {
  if (v->tag == VB_TAGGED) { vb_free(v->as.tagged.payload); v->as.tagged.payload = NULL; return; }
  if (!is_seq(v->tag)) return;
  for (size_t k = 0; k < v->as.seq.count; k++) free_contents(&v->as.seq.items[k]);
  free(v->as.seq.items);
  v->as.seq.items = NULL;
  v->as.seq.count = 0;
}

void vb_free(vb_value *v) {
  if (!v) return;
  free_contents(v);
  free(v);
}


int vb_is_utf8(const char *p, size_t len) {
  const unsigned char *s = (const unsigned char *)p;
  size_t i = 0;
  while (i < len) {
    unsigned char c = s[i];
    if (c < 0x80) { i += 1; continue; }
    size_t n; unsigned cp;
    if      ((c & 0xE0) == 0xC0) { n = 1; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { n = 2; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { n = 3; cp = c & 0x07; }
    else return 0;
    if (i + n >= len) return 0;
    for (size_t k = 1; k <= n; k++) {
      unsigned char cc = s[i + k];
      if ((cc & 0xC0) != 0x80) return 0;
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (n == 1 && cp < 0x80)    return 0;
    if (n == 2 && cp < 0x800)   return 0;
    if (n == 3 && cp < 0x10000) return 0;
    if (cp > 0x10FFFF)          return 0;
    if (cp >= 0xD800 && cp <= 0xDFFF) return 0;
    i += n + 1;
  }
  return 1;
}
