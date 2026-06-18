/* JRuby leg -- exported C-callable declarations (the JNI seam). Names only
 * JNIEnv/jobject + the neutral vb_value, never ruby.h/mruby.h. A JRuby host
 * embedding a native runtime includes this in its JNI TU and the matching
 * vb_cruby.h/vb_mruby.h in separate single-runtime TUs; vb_value crosses
 * between them. */
#ifndef VALUE_BRIDGE_JNI_H
#define VALUE_BRIDGE_JNI_H
#include <jni.h>
#include "vb.h"
#ifdef __cplusplus
extern "C" {
#endif
vb_value *vb_jni_from_node(JNIEnv *env, jobject node);     /* Node  -> owned vb_value */
jobject   vb_jni_to_node(JNIEnv *env, const vb_value *v);  /* vb_value -> Node */
void      vb_jni_free_owned(vb_value *v);                  /* free a JRuby-owned tree */
#ifdef __cplusplus
}
#endif
#endif
