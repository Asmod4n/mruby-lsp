// GENERATED at build time from the C tag table (src/vb_names.c) by
// jruby/build/gen_java_tags.c. Names and values both come from C via
// iteration -- no hand-kept copy, no parser. DO NOT EDIT.
package org.valuebridge;

public final class VbTags {
  private VbTags() {}

  // value-level tags (vb_tag), valid range [0, VB_TAG_MAX)
  public static final int VB_NIL = 0;
  public static final int VB_TRUE = 1;
  public static final int VB_FALSE = 2;
  public static final int VB_INT = 3;
  public static final int VB_FLOAT = 4;
  public static final int VB_SYMBOL = 5;
  public static final int VB_UTF8 = 6;
  public static final int VB_BYTES = 7;
  public static final int VB_BIGINT = 8;
  public static final int VB_ARRAY = 9;
  public static final int VB_HASH = 10;
  public static final int VB_RANGE = 11;
  public static final int VB_TAGGED = 12;
  public static final int VB_TAG_MAX = 13;

  // tag ids carried inside VB_TAGGED, valid range [1, VB_TAG_MAX_ID)
  public static final int VB_TAG_CLASS = 1;
  public static final int VB_TAG_MODULE = 2;
  public static final int VB_TAG_RATIONAL = 3;
  public static final int VB_TAG_COMPLEX = 4;
  public static final int VB_TAG_TIME = 5;
  public static final int VB_TAG_SET = 6;
  public static final int VB_TAG_PROC = 7;
  public static final int VB_TAG_MAX_ID = 8;

  /** Name of a value tag, e.g. 6 -> "VB_UTF8"; null if unknown. */
  public static String tagName(int tag) {
    switch (tag) {
      case 0: return "VB_NIL";
      case 1: return "VB_TRUE";
      case 2: return "VB_FALSE";
      case 3: return "VB_INT";
      case 4: return "VB_FLOAT";
      case 5: return "VB_SYMBOL";
      case 6: return "VB_UTF8";
      case 7: return "VB_BYTES";
      case 8: return "VB_BIGINT";
      case 9: return "VB_ARRAY";
      case 10: return "VB_HASH";
      case 11: return "VB_RANGE";
      case 12: return "VB_TAGGED";
      default: return null;
    }
  }

  /** Name of a tag id, e.g. 7 -> "VB_TAG_PROC"; null if unknown. */
  public static String tagIdName(int id) {
    switch (id) {
      case 1: return "VB_TAG_CLASS";
      case 2: return "VB_TAG_MODULE";
      case 3: return "VB_TAG_RATIONAL";
      case 4: return "VB_TAG_COMPLEX";
      case 5: return "VB_TAG_TIME";
      case 6: return "VB_TAG_SET";
      case 7: return "VB_TAG_PROC";
      default: return null;
    }
  }
}
