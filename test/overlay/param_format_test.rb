$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "mruby_lsp/param_format"

PF = MrubyLsp::ParamFormat
GA = MrubyLsp::GetArgs

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got: #{got.inspect}  want: #{want.inspect}" unless ok
end

# ── ParamFormat.render ────────────────────────────────────────────────────────
check.("render nil",            PF.render(nil),                      "()")
check.("render empty",          PF.render([]),                       "()")
check.("render unnamed req",    PF.render([[:req], [:req]]),         "(arg1, arg2)")
check.("render named req+opt",  PF.render([[:req, "x"], [:opt, "y"]]), "(x, y = ...)")
check.("render rest",           PF.render([[:rest, "vals"]]),        "(*vals)")
check.("render block",          PF.render([[:req, "a"], [:block, "blk"]]), "(a, &blk)")
check.("render keyrest unnamed",PF.render([[:keyrest, nil]]),        "(**opts)")
check.("render key",            PF.render([[:key, nil]]),            "(key:)")
check.("render sigil-only name",PF.render([[:rest, "*"]]),           "(*args)")
check.("render mixed full",
       PF.render([[:req, "a"], [:opt, "b"], [:rest, "r"], [:req, "c"], [:block, "blk"]]),
       "(a, b = ..., *r, c, &blk)")

# ── GetArgs.specs (format + &var extraction from a function body) ─────────────
spec = lambda { |src| GA.specs(src) }
check.("ga S",      spec.('mrb_get_args(mrb, "S", &str);'),                  [[:req, "str"]])
check.("ga S|i",    spec.('mrb_get_args(mrb, "S|i", &sub, &pos);'),          [[:req, "sub"], [:opt, "pos"]])
check.("ga ssi",    spec.('mrb_get_args(mrb, "ssi", &p, &plen, &m, &mlen, &found);'),
                    [[:req, "p"], [:req, "m"], [:req, "found"]])
check.("ga |oo&",   spec.('mrb_get_args(mrb, "|oo&", &ss, &obj, &blk);'),
                    [[:opt, "ss"], [:opt, "obj"], [:block, "blk"]])
check.("ga *!",     spec.('mrb_get_args(mrb, "*!", &vals, &len);'),          [[:rest, "vals"]])
check.("ga empty",  spec.('mrb_get_args(mrb, "");'),                         [])
check.("ga S: kw",  spec.('mrb_get_args(mrb, "S:", &str, &kwargs);'),        [[:req, "str"], [:keyrest, nil]])
check.("ga ? skip", spec.('mrb_get_args(mrb, "o?", &v, &given);'),           [[:req, "v"]])
check.("ga d (data)",spec.('mrb_get_args(mrb, "d", &ptr, &type);'),          [[:req, "ptr"]])
# multi-line call
check.("ga multiline",
       spec.("mrb_get_args(mrb,\n    \"S|i\",\n    &sub, &pos);"),
       [[:req, "sub"], [:opt, "pos"]])
# no parseable call -> nil (fall back to aspec)
check.("ga none",   spec.("return mrb_nil_value();"),                        nil)
check.("ga nonliteral fmt", spec.('mrb_get_args(mrb, fmt, &x);'),            nil)
check.("ga unknown directive", spec.('mrb_get_args(mrb, "Q", &x);'),         nil)
# complex var expr -> unnamed (numbered by render)
check.("ga complex var", spec.('mrb_get_args(mrb, "o", &self->field);'),     [[:req, nil]])
check.("ga complex var renders argN",
       PF.render(spec.('mrb_get_args(mrb, "oo", &a, &self->f);')),           "(a, arg2)")
# the body is bounded by the caller; first call in the text wins
check.("ga first call wins",
       spec.("mrb_int n;\n  mrb_get_args(mrb, \"i\", &n);\n  /* later */ mrb_get_args(mrb, \"S\", &s);"),
       [[:req, "n"]])

# ── end-to-end: parse then render (the real pipeline) ─────────────────────────
check.("e2e S|i", PF.render(spec.('mrb_get_args(mrb, "S|i", &sub, &pos);')), "(sub, pos = ...)")
check.("e2e ssi", PF.render(spec.('mrb_get_args(mrb, "ssi", &p, &plen, &m, &mlen, &found);')),
       "(p, m, found)")

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
