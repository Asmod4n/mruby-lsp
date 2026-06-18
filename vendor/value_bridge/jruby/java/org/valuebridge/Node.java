package org.valuebridge;

/**
 * Flat mirror of one vb_value node (see include/vb.h). One Java object per C
 * node; the native seam (vb_jni.c) copies between this and a real vb_value.
 *
 * Field meaning by tag (tag holds a vb_tag wire value; see VbNative.tagName):
 *   VB_INT                      -> i
 *   VB_FLOAT                    -> f
 *   VB_SYMBOL/UTF8/BYTES/BIGINT -> bytes   (UTF-8 text, raw bytes, or base-10 digits)
 *   VB_ARRAY                    -> items[n]
 *   VB_HASH                     -> items[2k] = key, items[2k+1] = value
 *   VB_RANGE                    -> items[2] = {begin,end}; aux = exclusive (0/1)
 *   VB_TAGGED                   -> tagId (VB_TAG_*) + payload
 * nil/true/false carry nothing but the tag.
 */
public final class Node {
  public int    tag;       // a vb_tag wire value
  public int    aux;       // VB_RANGE: exclusive (0/1)
  public long   i;         // VB_INT
  public double f;         // VB_FLOAT
  public byte[] bytes;     // VB_SYMBOL/UTF8/BYTES/BIGINT
  public Node[] items;     // VB_ARRAY (n), VB_HASH (2k), VB_RANGE (2)
  public int    tagId;     // VB_TAGGED: a VB_TAG_* id
  public Node   payload;   // VB_TAGGED: the carried value

  public Node() {}
}
