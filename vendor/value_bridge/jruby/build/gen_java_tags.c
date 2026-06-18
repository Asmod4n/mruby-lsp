/* gen_java_tags.c -- project the C tag table into Java at build time.
 *
 * This links against vb_names.c and ITERATES the enum ranges using the markers
 * in vb.h (VB_TAG_MAX, VB_TAG_MAX_ID). For each id it asks the C table for the
 * name (vb_tag_name / vb_tag_id_name). It hardcodes NO names and parses NO
 * source: the names come from the single C table, the values from the compiler.
 * Output is org/valuebridge/VbTags.java -- int constants for the Java leg's
 * logic, plus name() methods returning the SAME strings as interned Java
 * literals (constant-pool, deduplicated, no runtime JNI to read a name).
 *
 * Add a tag to vb.h + vb_names.c, rebuild, and the Java file regenerates. If a
 * name in vb_names.c drifts from vb.h, vb_names.c fails to compile first.
 *
 * Usage: cc gen_java_tags.c ../../src/vb.c ../../src/vb_names.c -I../../include \
 *           -o gen_java_tags && ./gen_java_tags > ../java/org/valuebridge/VbTags.java
 */
#include <stdio.h>
#include "vb.h"

int main(void) {
  printf("// GENERATED at build time from the C tag table (src/vb_names.c) by\n");
  printf("// jruby/build/gen_java_tags.c. Names and values both come from C via\n");
  printf("// iteration -- no hand-kept copy, no parser. DO NOT EDIT.\n");
  printf("package org.valuebridge;\n\n");
  printf("public final class VbTags {\n");
  printf("  private VbTags() {}\n\n");

  printf("  // value-level tags (vb_tag), valid range [0, VB_TAG_MAX)\n");
  for (int t = 0; t < VB_TAG_MAX; t++) {
    const char *n = vb_tag_name(t);
    if (n) printf("  public static final int %s = %d;\n", n, t);
  }
  printf("  public static final int VB_TAG_MAX = %d;\n\n", (int)VB_TAG_MAX);

  printf("  // tag ids carried inside VB_TAGGED, valid range [1, VB_TAG_MAX_ID)\n");
  for (int id = 1; id < VB_TAG_MAX_ID; id++) {
    const char *n = vb_tag_id_name((unsigned)id);
    if (n) printf("  public static final int %s = %d;\n", n, id);
  }
  printf("  public static final int VB_TAG_MAX_ID = %d;\n\n", (int)VB_TAG_MAX_ID);

  /* name(int) for value tags -- interned literals, same strings as the C table */
  printf("  /** Name of a value tag, e.g. 6 -> \"VB_UTF8\"; null if unknown. */\n");
  printf("  public static String tagName(int tag) {\n");
  printf("    switch (tag) {\n");
  for (int t = 0; t < VB_TAG_MAX; t++) {
    const char *n = vb_tag_name(t);
    if (n) printf("      case %d: return \"%s\";\n", t, n);
  }
  printf("      default: return null;\n");
  printf("    }\n  }\n\n");

  /* tagIdName(int) -- interned literals, same strings as the C table */
  printf("  /** Name of a tag id, e.g. 7 -> \"VB_TAG_PROC\"; null if unknown. */\n");
  printf("  public static String tagIdName(int id) {\n");
  printf("    switch (id) {\n");
  for (int id = 1; id < VB_TAG_MAX_ID; id++) {
    const char *n = vb_tag_id_name((unsigned)id);
    if (n) printf("      case %d: return \"%s\";\n", id, n);
  }
  printf("      default: return null;\n");
  printf("    }\n  }\n");

  printf("}\n");
  return 0;
}
