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

puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"
exit(fails.zero? ? 0 : 1)
