/* vb_names.c -- the one place enum names exist, for every leg.
 *
 * vb.h is the source of truth for the tag set; this file is the source of truth
 * for their NAMES. Each entry is built with VB_N(e), which stringifies the enum
 * constant (#e -> a string literal in .rodata) and takes its value straight from
 * the compiler ((int)(e)). So:
 *   - the names are literal C strings in the binary/lib, not heap allocations;
 *   - the numbers are never retyped -- the compiler supplies them;
 *   - referencing e.g. VB_TAG_PROC by name means a rename/removal in vb.h is a
 *     COMPILE error here, not silent drift;
 *   - no language is parsed and no regex is used: the C compiler reads the enum.
 *
 * Other runtimes (CRuby, JRuby via JNI, mruby) call vb_tag_name / vb_tag_id_name
 * instead of keeping their own copy of the names.
 */
#include "vb.h"
#include <stddef.h>

#define VB_N(e) { (int)(e), #e }

struct vb_name_entry { int id; const char *name; };

/* value-level tags (vb_tag) */
static const struct vb_name_entry VB_TAG_NAMES[] = {
  VB_N(VB_NIL),  VB_N(VB_TRUE),  VB_N(VB_FALSE), VB_N(VB_INT),    VB_N(VB_FLOAT),
  VB_N(VB_SYMBOL), VB_N(VB_UTF8), VB_N(VB_BYTES), VB_N(VB_BIGINT),
  VB_N(VB_ARRAY), VB_N(VB_HASH),  VB_N(VB_RANGE), VB_N(VB_TAGGED),
};

/* well-known tag ids carried inside VB_TAGGED (the closed built-in set) */
static const struct vb_name_entry VB_TAG_ID_NAMES[] = {
  VB_N(VB_TAG_CLASS), VB_N(VB_TAG_MODULE), VB_N(VB_TAG_RATIONAL),
  VB_N(VB_TAG_COMPLEX), VB_N(VB_TAG_TIME), VB_N(VB_TAG_SET),
  VB_N(VB_TAG_PROC),
  VB_N(VB_TAG_EXCEPTION_MRUBY), VB_N(VB_TAG_EXCEPTION_CRUBY),
  VB_N(VB_TAG_EXCEPTION_JRUBY),
};

const char *vb_tag_name(int tag) {
  for (size_t i = 0; i < sizeof VB_TAG_NAMES / sizeof *VB_TAG_NAMES; i++)
    if (VB_TAG_NAMES[i].id == tag) return VB_TAG_NAMES[i].name;
  return NULL;
}

const char *vb_tag_id_name(uint32_t id) {
  for (size_t i = 0; i < sizeof VB_TAG_ID_NAMES / sizeof *VB_TAG_ID_NAMES; i++)
    if ((uint32_t)VB_TAG_ID_NAMES[i].id == id) return VB_TAG_ID_NAMES[i].name;
  return NULL;
}
