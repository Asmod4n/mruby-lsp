/* JRuby native seam: BridgeValue.Node (Java) <-> vb_value (C).
 *
 * This is where a Node tree becomes a real vb_value built with the shared core
 * (src/vb.c: vb_new / vb_new_seq layout / vb_new_tagged), so a JRuby host that
 * embeds a native runtime exchanges the exact same neutral value the mruby and
 * CRuby legs speak. No serialization format on the path -- a structural copy.
 *
 * The bytes behind UTF8/BYTES/SYMBOL/BIGINT are copied OUT of the JVM into
 * malloc'd, owned spans (the JVM array is not pinned past the call); vb_free
 * never frees spans, so vb_jni_free_owned frees them before the structure.
 */
#include "vb_jni.h"         /* jni.h + vb.h */
#include <stdlib.h>
#include <string.h>

/* --- cached Node reflection ------------------------------------------------ */
static jclass    NodeClass;   /* global ref */
static jmethodID NodeCtor;
static jfieldID  f_tag, f_aux, f_i, f_f, f_bytes, f_items, f_tagId, f_payload;

static void cache(JNIEnv *env) {
  if (NodeClass) return;
  jclass c = (*env)->FindClass(env, "org/valuebridge/Node");
  NodeClass = (jclass)(*env)->NewGlobalRef(env, c);
  NodeCtor  = (*env)->GetMethodID(env, c, "<init>", "()V");
  f_tag     = (*env)->GetFieldID(env, c, "tag",   "I");
  f_aux     = (*env)->GetFieldID(env, c, "aux",   "I");
  f_i       = (*env)->GetFieldID(env, c, "i",     "J");
  f_f       = (*env)->GetFieldID(env, c, "f",     "D");
  f_bytes   = (*env)->GetFieldID(env, c, "bytes", "[B");
  f_items   = (*env)->GetFieldID(env, c, "items", "[Lorg/valuebridge/Node;");
  f_tagId   = (*env)->GetFieldID(env, c, "tagId", "I");
  f_payload = (*env)->GetFieldID(env, c, "payload", "Lorg/valuebridge/Node;");
}

/* --- Node -> vb_value (owned spans) ---------------------------------------- */

static vb_span span_from_bytes(JNIEnv *env, jbyteArray arr) {
  vb_span s = { NULL, 0 };
  if (!arr) return s;
  jsize len = (*env)->GetArrayLength(env, arr);
  char *p = (char *)malloc((size_t)len + 1);
  if (!p) return s;
  if (len) (*env)->GetByteArrayRegion(env, arr, 0, len, (jbyte *)p);
  p[len] = '\0';
  s.ptr = p; s.len = (size_t)len;
  return s;
}

static void fill_from_node(JNIEnv *env, jobject node, vb_value *out) {
  int tag = (*env)->GetIntField(env, node, f_tag);
  out->tag = (vb_tag)tag;
  switch (tag) {
    case VB_NIL: case VB_TRUE: case VB_FALSE: break;
    case VB_INT:   out->as.i = (int64_t)(*env)->GetLongField(env, node, f_i); break;
    case VB_FLOAT: out->as.f = (*env)->GetDoubleField(env, node, f_f); break;
    case VB_SYMBOL: case VB_UTF8: case VB_BYTES: case VB_BIGINT: {
      jbyteArray b = (jbyteArray)(*env)->GetObjectField(env, node, f_bytes);
      out->as.s = span_from_bytes(env, b);
      if (b) (*env)->DeleteLocalRef(env, b);
      break;
    }
    case VB_ARRAY: case VB_HASH: case VB_RANGE: {
      jobjectArray items = (jobjectArray)(*env)->GetObjectField(env, node, f_items);
      jsize count = items ? (*env)->GetArrayLength(env, items) : 0;
      out->aux = (*env)->GetIntField(env, node, f_aux);
      out->as.seq.count = (size_t)count;
      out->as.seq.items = count ? (vb_value *)calloc((size_t)count, sizeof(vb_value)) : NULL;
      for (jsize k = 0; k < count; k++) {
        jobject child = (*env)->GetObjectArrayElement(env, items, k);
        fill_from_node(env, child, &out->as.seq.items[k]);
        (*env)->DeleteLocalRef(env, child);
      }
      if (items) (*env)->DeleteLocalRef(env, items);
      break;
    }
    case VB_TAGGED: {
      out->as.tagged.id = (uint32_t)(*env)->GetIntField(env, node, f_tagId);
      jobject pay = (*env)->GetObjectField(env, node, f_payload);
      vb_value *p = vb_new();
      if (pay) { fill_from_node(env, pay, p); (*env)->DeleteLocalRef(env, pay); }
      out->as.tagged.payload = p;
      break;
    }
    default: break;
  }
}

vb_value *vb_jni_from_node(JNIEnv *env, jobject node) {
  cache(env);
  vb_value *v = vb_new();
  if (v) fill_from_node(env, node, v);
  return v;
}

/* --- vb_value -> Node ------------------------------------------------------- */

jobject vb_jni_to_node(JNIEnv *env, const vb_value *v) {
  cache(env);
  jobject n = (*env)->NewObject(env, NodeClass, NodeCtor);
  (*env)->SetIntField(env, n, f_tag, (jint)v->tag);
  switch (v->tag) {
    case VB_INT:   (*env)->SetLongField(env, n, f_i, (jlong)v->as.i); break;
    case VB_FLOAT: (*env)->SetDoubleField(env, n, f_f, (jdouble)v->as.f); break;
    case VB_SYMBOL: case VB_UTF8: case VB_BYTES: case VB_BIGINT: {
      jbyteArray b = (*env)->NewByteArray(env, (jsize)v->as.s.len);
      if (v->as.s.len) (*env)->SetByteArrayRegion(env, b, 0, (jsize)v->as.s.len, (const jbyte *)v->as.s.ptr);
      (*env)->SetObjectField(env, n, f_bytes, b);
      (*env)->DeleteLocalRef(env, b);
      break;
    }
    case VB_ARRAY: case VB_HASH: case VB_RANGE: {
      (*env)->SetIntField(env, n, f_aux, (jint)v->aux);
      jsize count = (jsize)v->as.seq.count;
      jobjectArray items = (*env)->NewObjectArray(env, count, NodeClass, NULL);
      for (jsize k = 0; k < count; k++) {
        jobject child = vb_jni_to_node(env, &v->as.seq.items[k]);
        (*env)->SetObjectArrayElement(env, items, k, child);
        (*env)->DeleteLocalRef(env, child);
      }
      (*env)->SetObjectField(env, n, f_items, items);
      (*env)->DeleteLocalRef(env, items);
      break;
    }
    case VB_TAGGED: {
      (*env)->SetIntField(env, n, f_tagId, (jint)v->as.tagged.id);
      jobject pay = v->as.tagged.payload ? vb_jni_to_node(env, v->as.tagged.payload) : NULL;
      (*env)->SetObjectField(env, n, f_payload, pay);
      if (pay) (*env)->DeleteLocalRef(env, pay);
      break;
    }
    default: break;  /* nil/true/false carry only the tag */
  }
  return n;
}

/* --- ownership: free the malloc'd spans, then the structure ----------------- */

static void free_spans(vb_value *v) {
  switch (v->tag) {
    case VB_SYMBOL: case VB_UTF8: case VB_BYTES: case VB_BIGINT:
      free((void *)v->as.s.ptr); v->as.s.ptr = NULL; break;
    case VB_ARRAY: case VB_HASH: case VB_RANGE:
      for (size_t k = 0; k < v->as.seq.count; k++) free_spans(&v->as.seq.items[k]);
      break;
    case VB_TAGGED:
      if (v->as.tagged.payload) free_spans(v->as.tagged.payload);
      break;
    default: break;
  }
}

void vb_jni_free_owned(vb_value *v) {
  if (!v) return;
  free_spans(v);   /* spans are ours (copied out of the JVM); vb_free won't */
  vb_free(v);      /* structural nodes + items[] blocks + tagged payload */
}

/* --- test/integration entry: Node -> vb_value -> Node through the core ------ */

JNIEXPORT jobject JNICALL
Java_org_valuebridge_VbNative_roundtrip(JNIEnv *env, jclass cls, jobject node) {
  (void)cls;
  vb_value *v = vb_jni_from_node(env, node);
  jobject out = vb_jni_to_node(env, v);
  vb_jni_free_owned(v);
  return out;
}
