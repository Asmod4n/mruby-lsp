/* Core (runtime-free) test: construction + vb_free covers nodes, seq items[],
 * and tagged payload with no leak/double-free. Runs under ASan/UBSan. */
#include "vb.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { printf("FAIL: %s (line %d)\n", #c, __LINE__); return 1; } } while (0)

int main(void) {
  /* scalars */
  vb_value *n = vb_new();            CHECK(n && n->tag == VB_NIL); vb_free(n);

  /* nested array [ "x", [1,2] ] with an inner owned seq */
  vb_value *a = vb_new_seq(VB_ARRAY, 2); CHECK(a && a->tag == VB_ARRAY && a->as.seq.count == 2);
  a->as.seq.items[0].tag = VB_UTF8;
  a->as.seq.items[0].as.s.ptr = "x"; a->as.seq.items[0].as.s.len = 1;
  vb_value *inner = vb_new_seq(VB_ARRAY, 2);
  inner->as.seq.items[0].tag = VB_INT; inner->as.seq.items[0].as.i = 1;
  inner->as.seq.items[1].tag = VB_INT; inner->as.seq.items[1].as.i = 2;
  a->as.seq.items[1] = *inner; free(inner);   /* move inner into slot; free shell only */
  vb_free(a);                                  /* must free outer items[] + inner items[] */

  /* hash payload as range */
  vb_value *r = vb_new_seq(VB_RANGE, 2); CHECK(r && r->tag == VB_RANGE);
  r->aux = 1; r->as.seq.items[0].tag = VB_INT; r->as.seq.items[1].tag = VB_INT;
  vb_free(r);

  /* tagged: payload is an owned subtree -> vb_free must recurse into it */
  vb_value *name = vb_new(); name->tag = VB_UTF8; name->as.s.ptr = "String"; name->as.s.len = 6;
  vb_value *t = vb_new_tagged(VB_TAG_CLASS, name);
  CHECK(t && t->tag == VB_TAGGED && t->as.tagged.id == VB_TAG_CLASS && t->as.tagged.payload == name);
  vb_free(t);                                  /* frees t + payload, not the borrowed "String" */

  /* tagged carrying a tagged carrying a seq (deep payload free) */
  vb_value *deep = vb_new_seq(VB_ARRAY, 1);
  deep->as.seq.items[0].tag = VB_INT; deep->as.seq.items[0].as.i = 7;
  vb_value *t1 = vb_new_tagged(VB_TAG_PROC, deep);
  vb_value *t2 = vb_new_tagged(VB_TAG_USER, t1);
  vb_free(t2);

  printf("ok\n");
  return 0;
}
