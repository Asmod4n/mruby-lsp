/*
 * mruby-irep-reflect — read-only return-type hints from a method's irep.
 *
 * MrubyIrepReflect.return_type(mod, sym) -> "String" | "Integer" | ... | nil
 *
 * Premise: never guess, never execute, never crash. We read the compiled irep
 * of a Ruby method and report a return type ONLY when the terminal instruction
 * makes it unambiguous (a literal-producing op, traced through MOVE). Anything
 * else — a send, a branch, an unmodelled terminal — yields nil, exactly what a
 * caller should show when the type is unknown.
 *
 * Stability: we touch only headers under mruby's include/ (class.h, proc.h,
 * irep.h, opcode.h, ops.h). The instruction decoder + operand widths come from
 * opcode.h's own PEEK/READ/FETCH macros (the same ones the VM uses), mirrored
 * here as decode_step so we also get the advanced pc. We do NOT link
 * mrb_decode_insn or the size tables from mruby-compiler/codegen.c — those are
 * implementation, not API.
 *
 * Safety: the method->irep path is gated for the body union (irep | func | mid):
 * CFUNC methods, CFUNC procs, and ALIAS procs (body is a mid, not an irep) are
 * all rejected before body.irep is ever read. The walk is bounded by ilen and
 * an instruction cap, every pc step is range-checked, and register indices are
 * bounded — a malformed or pathological irep degrades to nil, it cannot read
 * out of bounds.
 */

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/proc.h>
#include <mruby/irep.h>
#include <mruby/opcode.h>
#include <mruby/string.h>

#define IR_MAX_INSNS  200000   /* runaway guard */
#define IR_MAX_REGS   256      /* track writers only for modest register files */
#define IR_MOVE_DEPTH 16       /* MOVE-chain follow bound */

/*
 * decode_step: mirror of mrb_decode_insn (codegen.c) built purely from
 * opcode.h's FETCH machinery, but it RETURNS the advanced pc (the READ_* macros
 * move `pc` as they consume operands). EXT1/2/3 widen operands via the _1/_2/_3
 * FETCH variants, exactly as the VM decodes them.
 */
static const mrb_code *
decode_step(const mrb_code *pc, struct mrb_insn_data *out)
{
  uint32_t a = 0;
  uint16_t b = 0, c = 0;
  out->addr = pc;
  mrb_code insn = READ_B();
  switch (insn) {
#define OPCODE(i,x) case OP_##i: FETCH_##x(); break;
#include <mruby/ops.h>
#undef OPCODE
  }
  switch (insn) {
  case OP_EXT1:
    insn = READ_B();
    switch (insn) {
#define OPCODE(i,x) case OP_##i: FETCH_##x##_1(); break;
#include <mruby/ops.h>
#undef OPCODE
    }
    break;
  case OP_EXT2:
    insn = READ_B();
    switch (insn) {
#define OPCODE(i,x) case OP_##i: FETCH_##x##_2(); break;
#include <mruby/ops.h>
#undef OPCODE
    }
    break;
  case OP_EXT3:
    insn = READ_B();
    switch (insn) {
#define OPCODE(i,x) case OP_##i: FETCH_##x##_3(); break;
#include <mruby/ops.h>
#undef OPCODE
    }
    break;
  default:
    break;
  }
  out->insn = insn;
  out->a = a;
  out->b = b;
  out->c = c;
  return pc;
}

/* The class of the value an op deposits in R[a], when the op alone determines
 * it. NULL = not type-determining (a send, an arithmetic op, etc.). */
static const char *
op_value_type(const struct mrb_irep *irep, mrb_code insn, uint16_t b)
{
  switch (insn) {
  case OP_STRING: case OP_STRCAT:                 return "String";
  case OP_SYMBOL: case OP_LOADSYM: case OP_INTERN: return "Symbol";
  case OP_ARRAY:  case OP_ARRAY2:                  return "Array";
  case OP_HASH:   case OP_HASHADD: case OP_HASHCAT:return "Hash";
  case OP_LOADI8: case OP_LOADINEG: case OP_LOADI__1:
  case OP_LOADI_0: case OP_LOADI_1: case OP_LOADI_2: case OP_LOADI_3:
  case OP_LOADI_4: case OP_LOADI_5: case OP_LOADI_6: case OP_LOADI_7:
  case OP_LOADI16: case OP_LOADI32:               return "Integer";
  case OP_LOADNIL:                                return "NilClass";
  case OP_LOADTRUE:                               return "TrueClass";
  case OP_LOADFALSE:                              return "FalseClass";
  case OP_LAMBDA: case OP_BLOCK:                  return "Proc";
  case OP_RANGE_INC: case OP_RANGE_EXC:           return "Range";
  case OP_LOADL:
    if (irep && b < irep->plen) {
      uint32_t tt = irep->pool[b].tt;
      /* tt packs a string length for STR/SSTR; numbers carry IREP_TT_NFLAG and
       * are exact small values. So: number flag -> Integer (or Float), else a
       * pooled string. */
      if (tt & IREP_TT_NFLAG) return (tt == IREP_TT_FLOAT) ? "Float" : "Integer";
      return "String";
    }
    return NULL;
  default:
    return NULL;
  }
}

static mrb_value
analyze_return(mrb_state *mrb, const struct mrb_irep *irep)
{
  if (!irep || !irep->iseq || irep->ilen == 0) return mrb_nil_value();
  uint16_t nregs = irep->nregs;
  if (nregs == 0 || nregs > IR_MAX_REGS) return mrb_nil_value();

  const mrb_code *pc  = irep->iseq;
  const mrb_code *end = irep->iseq + irep->ilen;

  uint8_t  w_op[IR_MAX_REGS];   /* last op that wrote R[i] */
  uint16_t w_b[IR_MAX_REGS];    /* its b operand (MOVE source reg / LOADL pool idx) */
  for (uint16_t i = 0; i < nregs; i++) { w_op[i] = OP_NOP; w_b[i] = 0; }

  int saw_branch = 0;
  struct mrb_insn_data last;
  last.insn = OP_NOP; last.a = 0; last.b = 0; last.c = 0; last.addr = pc;
  long count = 0;

  while (pc < end) {
    if (++count > IR_MAX_INSNS) return mrb_nil_value();
    struct mrb_insn_data d;
    const mrb_code *next = decode_step(pc, &d);
    if (next <= pc || next > end) return mrb_nil_value(); /* overrun / no progress */

    switch (d.insn) {
    /* any control flow means multiple paths -> we cannot prove one type */
    case OP_JMP: case OP_JMPIF: case OP_JMPNOT: case OP_JMPNIL: case OP_JMPUW:
    case OP_EXCEPT: case OP_RESCUE: case OP_RAISEIF: case OP_BREAK:
      saw_branch = 1;
      break;
    /* terminals / non-dest ops: do NOT record a writer for R[a] */
    case OP_RETURN: case OP_RETURN_BLK: case OP_RETNIL: case OP_RETTRUE:
    case OP_RETFALSE: case OP_RETSELF: case OP_STOP:
      break;
    default:
      if (d.a < nregs) { w_op[d.a] = (uint8_t)d.insn; w_b[d.a] = d.b; }
      break;
    }

    last = d;
    pc = next;
  }

  if (saw_branch) return mrb_nil_value();

  const char *t = NULL;
  switch (last.insn) {
  case OP_RETNIL:   t = "NilClass";   break;
  case OP_RETTRUE:  t = "TrueClass";  break;
  case OP_RETFALSE: t = "FalseClass"; break;
  case OP_RETURN:
  case OP_RETURN_BLK: {
    uint32_t reg = last.a;
    for (int depth = 0; depth < IR_MOVE_DEPTH && reg < nregs; depth++) {
      uint8_t op = w_op[reg];
      if (op == OP_MOVE) { reg = w_b[reg]; continue; } /* follow the copy */
      t = op_value_type(irep, op, w_b[reg]);
      break;
    }
    break;
  }
  default:
    break; /* RETSELF or an unmodelled terminal -> unknown */
  }

  return t ? mrb_str_new_cstr(mrb, t) : mrb_nil_value();
}

/* MrubyIrepReflect.return_type(mod, sym) — mod already resolved to a class/
 * module by the caller (Ruby decides instance vs singleton by passing the class
 * or its singleton_class). Returns a class-name String, or nil when unknown. */
static mrb_value
m_return_type(mrb_state *mrb, mrb_value self)
{
  mrb_value mod;
  mrb_sym mid;
  mrb_get_args(mrb, "on", &mod, &mid);
  (void)self;

  switch (mrb_type(mod)) {
  case MRB_TT_CLASS: case MRB_TT_MODULE: case MRB_TT_SCLASS:
    break;
  default:
    return mrb_nil_value();
  }
  struct RClass *c = mrb_class_ptr(mod);

  mrb_method_t m = mrb_method_search_vm(mrb, &c, mid);
  if (MRB_METHOD_UNDEF_P(m)) return mrb_nil_value();
  if (MRB_METHOD_CFUNC_P(m)) return mrb_nil_value();          /* C method -> not irep */

  const struct RProc *p = MRB_METHOD_PROC(m);
  if (!p) return mrb_nil_value();

  /* unwrap aliases: an alias proc's body is a mid (symbol), NOT an irep. follow
   * upper to the real proc; bound the chain. */
  int guard = 0;
  while (p && MRB_PROC_ALIAS_P(p) && guard++ < 32) p = p->upper;
  if (!p) return mrb_nil_value();
  if (MRB_PROC_CFUNC_P(p)) return mrb_nil_value();             /* alias to a C method */

  const struct mrb_irep *irep = p->body.irep;
  if (!irep) return mrb_nil_value();

  return analyze_return(mrb, irep);
}

void
mrb_mruby_irep_reflect_gem_init(mrb_state *mrb)
{
  struct RClass *m = mrb_define_module(mrb, "MrubyIrepReflect");
  mrb_define_module_function(mrb, m, "return_type", m_return_type, MRB_ARGS_REQ(2));
}

void
mrb_mruby_irep_reflect_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
