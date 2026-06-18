MRuby::Gem::Specification.new('mruby-irep-reflect') do |spec|
  spec.license = 'MIT'
  spec.author  = 'mruby-lsp'
  spec.summary = 'Read-only return-type hints from a method irep, using only public mruby headers'

  # Stands alone: needs nothing but the headers under mruby's own include/ —
  #   class.h  (mrb_method_search_vm), proc.h (RProc + CFUNC/ALIAS macros),
  #   irep.h   (mrb_irep, mrb_irep_pool, IREP_TT_*),
  #   opcode.h (OP_* enum + the PEEK/READ/FETCH decode machinery),
  #   ops.h    (the opcode x-macro list).
  # No mruby-compiler symbols (mrb_decode_insn / size tables live in codegen.c,
  # which is implementation, not API) — we mirror the header FETCH macros in our
  # own decode_step so the operand widths come from THIS build's opcode.h.
end
