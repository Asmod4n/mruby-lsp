package org.valuebridge;

/**
 * Native seam for the JRuby leg. The only cross-runtime operation that needs C
 * is converting a Node to a real vb_value and back; everything else (produce/
 * consume, tag names via VbTags) is pure Java.
 *
 * roundtrip() exists primarily so the leg can be tested against the SAME vb.c
 * core the mruby/CRuby legs use: a Node -> vb_value (vb_jni_from_node) -> Node
 * (vb_jni_to_node) trip proves the Java<->C mapping is lossless and matches the
 * neutral layout. A real embedding host calls vb_jni_from_node/to_node directly.
 */
public final class VbNative {
  private VbNative() {}

  private static boolean loaded = false;

  /** Load the JNI library (libvalue_bridge_jni). Idempotent. */
  public static synchronized void load(String absolutePath) {
    if (!loaded) { System.load(absolutePath); loaded = true; }
  }

  /** Node -> C vb_value -> Node, through the shared core. For tests/integration. */
  public static native Node roundtrip(Node node);
}
