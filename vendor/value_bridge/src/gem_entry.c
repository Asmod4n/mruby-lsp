/* Mandatory mrbgem entry points. A mrbgem with C sources must define these
 * (mruby's generated gem_init.c references them for every gem).
 *
 * value_bridge exposes the __ValueBridge::Tagged fallback wrapper. A value the
 * mruby leg can't represent as floor or a natively-decodable tag in THIS build
 * is handed back wrapped in a Tagged so its bytes survive as an inspectable
 * object instead of being lost. The module is named "__ValueBridge" ON PURPOSE:
 * a Ruby constant can't begin with "_", so the mruby PARSER rejects
 * "__ValueBridge" in user .rb -- defining it from C is the one legal path, and
 * it makes the module (and Tagged) impossible to name, reopen, or instantiate
 * from user Ruby. The LSP additionally hides any __-prefixed module/class from
 * completion.
 *
 * Tagged is defined here in C (not mrblib) precisely because mrblib can't write
 * `module __ValueBridge` -- the parser forbids it. The class is tiny: two
 * read-only attributes and value equality. */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/variable.h>
#include "vb.h"

#define VB_MODULE_NAME "__ValueBridge"

/* @tag (Integer) and @payload (any) -- set once at construction, read-only. */
static mrb_value
tagged_init(mrb_state *mrb, mrb_value self)
{
  mrb_value tag, payload;
  mrb_get_args(mrb, "oo", &tag, &payload);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@tag"), mrb_to_int(mrb, tag));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@payload"), payload);
  return self;
}

static mrb_value
tagged_tag(mrb_state *mrb, mrb_value self)
{
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@tag"));
}

static mrb_value
tagged_payload(mrb_state *mrb, mrb_value self)
{
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@payload"));
}

/* Value equality: same class, same tag, same payload (== on payload). */
static mrb_value
tagged_eq(mrb_state *mrb, mrb_value self)
{
  mrb_value other;
  mrb_get_args(mrb, "o", &other);
  if (!mrb_obj_is_kind_of(mrb, other, mrb_class(mrb, self))) return mrb_false_value();

  mrb_sym tsym = mrb_intern_lit(mrb, "@tag");
  mrb_sym psym = mrb_intern_lit(mrb, "@payload");
  if (!mrb_equal(mrb, mrb_iv_get(mrb, self, tsym), mrb_iv_get(mrb, other, tsym)))
    return mrb_false_value();
  return mrb_bool_value(mrb_equal(mrb, mrb_iv_get(mrb, self, psym),
                                       mrb_iv_get(mrb, other, psym)));
}

void
mrb_mruby_value_bridge_gem_init(mrb_state *mrb)
{
  struct RClass *mod = mrb_define_module(mrb, VB_MODULE_NAME);
  struct RClass *tagged = mrb_define_class_under(mrb, mod, "Tagged", mrb->object_class);

  mrb_define_method(mrb, tagged, "initialize", tagged_init,    MRB_ARGS_REQ(2));
  mrb_define_method(mrb, tagged, "tag",        tagged_tag,     MRB_ARGS_NONE());
  mrb_define_method(mrb, tagged, "payload",    tagged_payload, MRB_ARGS_NONE());
  mrb_define_method(mrb, tagged, "==",         tagged_eq,      MRB_ARGS_REQ(1));

  /* Tag-id constants, kept in lockstep with vb.h (single source of truth). */
  mrb_define_const(mrb, tagged, "CLASS",           mrb_fixnum_value(VB_TAG_CLASS));
  mrb_define_const(mrb, tagged, "MODULE",          mrb_fixnum_value(VB_TAG_MODULE));
  mrb_define_const(mrb, tagged, "RATIONAL",        mrb_fixnum_value(VB_TAG_RATIONAL));
  mrb_define_const(mrb, tagged, "COMPLEX",         mrb_fixnum_value(VB_TAG_COMPLEX));
  mrb_define_const(mrb, tagged, "TIME",            mrb_fixnum_value(VB_TAG_TIME));
  mrb_define_const(mrb, tagged, "SET",             mrb_fixnum_value(VB_TAG_SET));
  mrb_define_const(mrb, tagged, "PROC",            mrb_fixnum_value(VB_TAG_PROC));
  mrb_define_const(mrb, tagged, "EXCEPTION_MRUBY", mrb_fixnum_value(VB_TAG_EXCEPTION_MRUBY));
  mrb_define_const(mrb, tagged, "EXCEPTION_CRUBY", mrb_fixnum_value(VB_TAG_EXCEPTION_CRUBY));
  mrb_define_const(mrb, tagged, "EXCEPTION_JRUBY", mrb_fixnum_value(VB_TAG_EXCEPTION_JRUBY));
}

void
mrb_mruby_value_bridge_gem_final(mrb_state *mrb) { (void)mrb; }
