$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "mruby_lsp/c_return_type"
C = MrubyLsp::CReturnType

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got: #{got.inspect}  want: #{want.inspect}" unless ok
end

# Build clangd-shaped AST nodes (exact structure observed from clangd 18 ast).
def declref(name) = { kind: "DeclRef", role: "expression", detail: name }
def cast(child)   = { kind: "ImplicitCast", role: "expression", detail: "FunctionToPointerDecay", children: [child] }
def call(name, *args) = { kind: "Call", role: "expression", children: [cast(declref(name)), *args] }
def ret(expr)     = { kind: "Return", role: "statement", children: [expr] }
def func(*stmts)  = { kind: "Function", role: "declaration", detail: "f",
                      children: [{ kind: "Compound", role: "statement", children: stmts }] }

check.("exact: str_new_cstr -> String", C.of(func(ret(call("mrb_str_new_cstr")))), "String")
check.("exact: fixnum_value -> Integer", C.of(func(ret(call("mrb_fixnum_value")))), "Integer")
check.("exact: nil_value -> NilClass", C.of(func(ret(call("mrb_nil_value")))), "NilClass")
check.("exact: float_value -> Float", C.of(func(ret(call("mrb_float_value")))), "Float")
check.("exact: hash_new -> Hash", C.of(func(ret(call("mrb_hash_new")))), "Hash")
check.("exact: assoc_new -> Array", C.of(func(ret(call("mrb_assoc_new")))), "Array")
check.("prefix: str_dup -> String", C.of(func(ret(call("mrb_str_dup")))), "String")
check.("prefix: ary_new_capa -> Array", C.of(func(ret(call("mrb_ary_new_capa")))), "Array")

# unanimous vs disagreement
check.("two returns same -> String",
       C.of(func(ret(call("mrb_str_new_cstr")), ret(call("mrb_str_new_lit")))), "String")
check.("two returns differ -> nil",
       C.of(func(ret(call("mrb_str_new_cstr")), ret(call("mrb_fixnum_value")))), nil)
check.("known + unknown path -> nil (never guess)",
       C.of(func(ret(call("mrb_str_new_cstr")), ret(call("other_thing")))), nil)

# unmappable forms
check.("return self (DeclRef) -> nil", C.of(func(ret(declref("self")))), nil)
check.("unknown constructor -> nil", C.of(func(ret(call("frobnicate")))), nil)
check.("ambiguous mrb_bool_value -> nil", C.of(func(ret(call("mrb_bool_value")))), nil)
check.("mrb_obj_value (any class) -> nil", C.of(func(ret(call("mrb_obj_value")))), nil)
check.("no return -> nil", C.of(func), nil)
check.("no body -> nil", C.of({ kind: "Function", role: "declaration", detail: "f", children: [] }), nil)
check.("non-hash -> nil", C.of(nil), nil)

# constructor_class direct
check.("constructor_class str prefix", C.constructor_class("mrb_str_cat"), "String")
check.("constructor_class unknown", C.constructor_class("nope"), nil)

# ── fresh-instance-of-receiver detection + interprocedural step ───────────────
# Node shapes below mirror what clangd 18 actually emits (captured from a real
# textDocument/ast over mruby-io's io_s_for_fd): ParmVar params, a Var under a
# Decl, mrb_class_ptr(<receiver>), and casts the unwrap already skips.
R = MrubyLsp::CReturnType::RECEIVER
def parm(name) = { kind: "ParmVar", role: "declaration", detail: name }
def var(name, init) = { kind: "Decl", role: "statement",
                        children: [{ kind: "Var", role: "declaration", detail: name,
                                     children: [init].compact }] }
# clangd nests ParmVar under the FunctionProto (type) child — match that shape.
def func_p(params, *stmts) = { kind: "Function", role: "declaration", detail: "f",
                               children: [{ kind: "FunctionProto", role: "type",
                                            children: params.map { |p| parm(p) } },
                                          { kind: "Compound", role: "statement", children: stmts }] }
def classref(p) = call("mrb_class_ptr", cast(declref(p)))   # mrb_class_ptr(<param>)

# direct: return mrb_obj_value(mrb_obj_alloc(mrb, ttype, mrb_class_ptr(self)))
direct = func_p(%w[mrb self],
                ret(call("mrb_obj_value",
                         call("mrb_obj_alloc", cast(declref("mrb")), cast(declref("ttype")), classref("self")))))
check.("alloc of receiver class -> RECEIVER", C.of(direct), R)

# mrb_obj_new(mrb, mrb_class_ptr(self), argc, argv) -> RECEIVER (class arg idx 1)
objnew = func_p(%w[mrb self],
                ret(call("mrb_obj_new", cast(declref("mrb")), classref("self"),
                         cast(declref("argc")), cast(declref("argv")))))
check.("mrb_obj_new of receiver class -> RECEIVER", C.of(objnew), R)

# alloc of a NON-receiver class -> nil (never guess a fixed class)
other = func_p(%w[mrb self],
               ret(call("mrb_obj_value",
                        call("mrb_obj_alloc", cast(declref("mrb")), cast(declref("ttype")), classref("notself")))))
check.("alloc of other class -> nil", C.of(other), nil)

# the real io_s_for_fd shape: fresh receiver obj via a local, returned THROUGH a
# helper (io_init) that hands back its mrb_value argument.
for_fd = func_p(%w[mrb klass],
                var("c", classref("klass")),
                var("obj", call("mrb_obj_value",
                                call("mrb_obj_alloc", cast(declref("mrb")), cast(declref("ttype")), cast(declref("c"))))),
                ret(call("io_init", cast(declref("mrb")), cast(declref("obj")))))
io_init = func_p(%w[mrb io], ret(cast(declref("io"))))             # returns its 2nd arg
resolver = ->(n) { n == "io_init" ? C.classify(io_init) : nil }

check.("helper io_init classify -> [:arg, 1]", C.classify(io_init), [:arg, 1])
check.("for_fd via helper (resolver) -> RECEIVER", C.of(for_fd, resolve_callee: resolver), R)
check.("for_fd no resolver -> nil (helper unknown)", C.of(for_fd), nil)

# clangd sometimes omits ParmVar over a ranged AST: a bare non-local return is the
# value param (standard sig) -> [:arg, 1] by fallback.
check.("paramless identity helper -> [:arg, 1]", C.classify(func(ret(cast(declref("io"))))), [:arg, 1])

# a helper returning a FIXED class passes that class straight through
mk = func_p(%w[mrb self], ret(call("mrb_str_new_cstr")))
main_mk = func_p(%w[mrb self], ret(call("make_str", cast(declref("mrb")))))
check.("helper fixed class passes through -> String",
       C.of(main_mk, resolve_callee: ->(n) { n == "make_str" ? C.classify(mk) : nil }), "String")

# public `of` never surfaces the internal [:arg, k] (returning self is ambiguous:
# instance vs class) -> nil
check.("return receiver param -> nil (public)", C.of(func_p(%w[mrb self], ret(cast(declref("self"))))), nil)

puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"
exit(fails.zero? ? 0 : 1)
