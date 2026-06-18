/* CRuby-only TU. One thin handler per op -- Ruby decides which op to call; this
 * TU never dispatches and carries no singleton flag (instance vs singleton are
 * distinct methods). Each handler hands its args to the matching mrb_bridge_*
 * entry and materializes the returned vb_value via value_bridge (vb_to_value).
 * No mruby headers here; no marshalling here -- value_bridge owns both. */
#include <ruby.h>
#include <stdlib.h>
#include "vb_cruby.h"   /* vb_to_value (+ ruby.h + vb.h) */
#include "bridge.h"     /* the ops, returning vb_value* (+ vb.h) */

typedef struct { void *h; } reflect_t;

static void reflect_free(void *p) {
  reflect_t *r = (reflect_t *)p;
  if (r) { if (r->h) mrb_bridge_close(r->h); xfree(r); }
}
static const rb_data_type_t reflect_type = {
  "MrubyReflect", { 0, reflect_free, 0 }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};
static reflect_t *unwrap(VALUE self) {
  reflect_t *r; TypedData_Get_Struct(self, reflect_t, &reflect_type, r);
  if (!r->h) rb_raise(rb_eRuntimeError, "reflect state is closed");
  return r;
}
/* vb_value tree -> Ruby value; NULL (absent/exception) -> nil. Always frees. */
static VALUE materialize(vb_value *v) {
  VALUE out = v ? vb_to_value(v) : Qnil;
  vb_free(v);
  return out;
}

static VALUE m_alloc(VALUE klass) {
  reflect_t *r = ALLOC(reflect_t); r->h = NULL;
  return TypedData_Wrap_Struct(klass, &reflect_type, r);
}
static VALUE m_init(VALUE self) {
  reflect_t *r; TypedData_Get_Struct(self, reflect_t, &reflect_type, r);
  r->h = mrb_bridge_open();
  if (!r->h) rb_raise(rb_eRuntimeError, "mrb_open failed");
  return self;
}
static VALUE m_close(VALUE self) {
  reflect_t *r; TypedData_Get_Struct(self, reflect_t, &reflect_type, r);
  if (r->h) { mrb_bridge_close(r->h); r->h = NULL; }
  return Qnil;
}

static VALUE m_ancestors(VALUE self, VALUE name) {
  reflect_t *r = unwrap(self); Check_Type(name, T_STRING);
  return materialize(mrb_bridge_ancestors(r->h, RSTRING_PTR(name), RSTRING_LEN(name)));
}
static VALUE m_instance_methods(int argc, VALUE *argv, VALUE self) {
  reflect_t *r = unwrap(self);
  VALUE name, inc; rb_scan_args(argc, argv, "11", &name, &inc); Check_Type(name, T_STRING);
  return materialize(mrb_bridge_instance_methods(r->h, RSTRING_PTR(name), RSTRING_LEN(name), RTEST(inc) ? 1 : 0));
}
static VALUE m_private_instance_methods(int argc, VALUE *argv, VALUE self) {
  reflect_t *r = unwrap(self);
  VALUE name, inc; rb_scan_args(argc, argv, "11", &name, &inc); Check_Type(name, T_STRING);
  return materialize(mrb_bridge_private_instance_methods(r->h, RSTRING_PTR(name), RSTRING_LEN(name), RTEST(inc) ? 1 : 0));
}
static VALUE m_constants(VALUE self, VALUE name) {
  reflect_t *r = unwrap(self); Check_Type(name, T_STRING);
  return materialize(mrb_bridge_constants(r->h, RSTRING_PTR(name), RSTRING_LEN(name)));
}
static VALUE m_singleton_methods(int argc, VALUE *argv, VALUE self) {
  reflect_t *r = unwrap(self);
  VALUE name, inc; rb_scan_args(argc, argv, "11", &name, &inc); Check_Type(name, T_STRING);
  return materialize(mrb_bridge_singleton_methods(r->h, RSTRING_PTR(name), RSTRING_LEN(name), RTEST(inc) ? 1 : 0));
}
static VALUE m_anchor_addr(VALUE self) {
  reflect_t *r = unwrap(self);
  return materialize(mrb_bridge_anchor_addr(r->h));
}
static VALUE m_platform(VALUE self) {
  reflect_t *r = unwrap(self);
  return materialize(mrb_bridge_platform(r->h));
}
static VALUE m_net_schema(VALUE self, VALUE cls) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING);
  return materialize(mrb_bridge_net_schema(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls)));
}
static VALUE m_source_location(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_source_location(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                                RSTRING_PTR(meth), RSTRING_LEN(meth)));
}
static VALUE m_singleton_source_location(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_singleton_source_location(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                                          RSTRING_PTR(meth), RSTRING_LEN(meth)));
}
static VALUE m_parameters(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_parameters(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                           RSTRING_PTR(meth), RSTRING_LEN(meth)));
}
static VALUE m_singleton_parameters(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_singleton_parameters(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                                     RSTRING_PTR(meth), RSTRING_LEN(meth)));
}
static VALUE m_cfunc_addr(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  /* faithful: Integer address (Bigint if it exceeds mrb_int) or nil. */
  return materialize(mrb_bridge_cfunc_addr(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                           RSTRING_PTR(meth), RSTRING_LEN(meth)));
}
static VALUE m_singleton_cfunc_addr(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_singleton_cfunc_addr(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                                     RSTRING_PTR(meth), RSTRING_LEN(meth)));
}

static VALUE m_return_type(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_return_type(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                            RSTRING_PTR(meth), RSTRING_LEN(meth)));
}
static VALUE m_singleton_return_type(VALUE self, VALUE cls, VALUE meth) {
  reflect_t *r = unwrap(self); Check_Type(cls, T_STRING); Check_Type(meth, T_STRING);
  return materialize(mrb_bridge_singleton_return_type(r->h, RSTRING_PTR(cls), RSTRING_LEN(cls),
                                                      RSTRING_PTR(meth), RSTRING_LEN(meth)));
}

void Init_mruby_reflect(void) {
  VALUE c = rb_define_class("MrubyReflect", rb_cObject);
  rb_define_alloc_func(c, m_alloc);
  rb_define_method(c, "initialize", m_init, 0);
  rb_define_method(c, "close", m_close, 0);
  rb_define_method(c, "ancestors", m_ancestors, 1);
  rb_define_method(c, "instance_methods", m_instance_methods, -1);
  rb_define_method(c, "private_instance_methods", m_private_instance_methods, -1);
  rb_define_method(c, "constants", m_constants, 1);
  rb_define_method(c, "singleton_methods", m_singleton_methods, -1);
  rb_define_method(c, "anchor_addr", m_anchor_addr, 0);
  rb_define_method(c, "platform", m_platform, 0);
  rb_define_method(c, "net_schema", m_net_schema, 1);
  rb_define_method(c, "source_location", m_source_location, 2);
  rb_define_method(c, "singleton_source_location", m_singleton_source_location, 2);
  rb_define_method(c, "return_type", m_return_type, 2);
  rb_define_method(c, "singleton_return_type", m_singleton_return_type, 2);
  rb_define_method(c, "parameters", m_parameters, 2);
  rb_define_method(c, "singleton_parameters", m_singleton_parameters, 2);
  rb_define_method(c, "cfunc_addr", m_cfunc_addr, 2);
  rb_define_method(c, "singleton_cfunc_addr", m_singleton_cfunc_addr, 2);
}
