# GOTCHAS — full-LSP conformance run (in-sandbox)

Running the REAL server against ruby-lsp's vendored vectors, to catch real
errors. Environment bootstrap + per-feature findings, recorded as we go.

## Method provenance from the live VM (USE for hover/definition/completion)
We can attribute every visible method to its TRUE origin, purely from
reflection (verified by running against core classes):
  - True MRO in real order, mixins included: ancestors("String") ->
    [String, Comparable, Object, Kernel, BasicObject].
  - True owner per method: we enumerate each ancestor's OWN methods separately,
    so String#< -> Comparable (an include), String#class -> Kernel (an include),
    String#== -> String (own, overriding BasicObject#==).
  - CLASS vs MODULE per ancestor by an exact invariant: only a class has
    BasicObject in its own ancestry (a module never can — you can't include a
    class). So in an MRO: the chain of CLASSES is the inheritance line, MODULES
    interspersed are includes (in real position), anything before the class
    itself is a prepend.
  - The index already stores ancestors + per-method owners, so provenance is
    computable now; it's just not surfaced in hover/completion text yet. ruby-lsp
    shows the owner — we have richer data ("included from Comparable" vs
    "inherited from Numeric"), and it's the REAL resolution (monkey-patches,
    prepends, reopens included).

## Bridge ops (ext/mruby_reflect) — pure VM reflection, no logic
ancestors, instance_methods, private_instance_methods (NEW), constants,
source_location, parameters, cfunc_addr, anchor_addr, singleton_methods,
return_type/singleton_return_type (NEW, Stage 2), close.

## irep return-type reflection (mruby-irep-reflect) — public headers ONLY
mruby exposes NO stable public irep-instruction API: `mrb_decode_insn`, the
static `mrb_insn_size[]` tables, and `mrb_prev_pc` all live in
mruby-compiler/core/codegen.c — compiler internals in a .c, unstable. DO NOT
reach into them. But opcode.h (a header, allowed) carries the COMPLETE decode
machinery (PEEK/READ/FETCH incl. EXT1/2/3 via FETCH_*_1/_2/_3) + ops.h's opcode
x-macro. Mirror it as a header-only `decode_step(pc, &data)`: the READ_* macros
advance pc, so it RETURNS the advanced pc — no size table needed, operand widths
track the build's own opcode.h. Rule of thumb: anything under include/ is fair
game (MRB_API or not); anything in a core .c is not.

ALIAS TRAP (load-bearing): RProc body is a union {irep | func | mid}. Before
reading body.irep you MUST: MRB_METHOD_CFUNC_P -> nil (C method = Stage 3);
then `while (MRB_PROC_ALIAS_P(p)) p = p->upper;` (an alias body is a `mid`, not an
irep — reading body.irep on it is OOB), bounded guard < 32; then re-check
MRB_PROC_CFUNC_P (alias may target a C method) -> nil; only then body.irep.
Modeled on mruby-method's proven unwrap. (value_bridge's MRB_TT_PROC path checks
CFUNC but not ALIAS — a latent hole, harmless there.) Analysis is a bounded
single forward pass tracking the last writer per dest register; ANY jump opcode
-> nil (branches unsound); only type-unambiguous terminal opcodes map to a type.
There is NO ".new special case": .new returns via OP_SEND like any call, and
sends -> nil; recursion happens host-side in type_of, never in the irep walk.

## Stage 2 return type lives on Entry, refreshed by the existing lifecycle
The irep type is stored on `Entry#return_type` at populate (VM side) and at
harvest (buffer side, via Stage-1 AST). NOT lazy, NOT a separate cache. This
rides the dynamic machinery already in place: the index is rebuilt+swapped from a
fresh VM on rebuild, and the buffer overlay returns the buffer twin (fresh per
keystroke) when a method is open — so an edit in ANY tab is reflected (cross-file
too), compiled-but-not-open methods keep the irep type, and a closed tab reverts
to it. Nothing holds a type that outlives the live VM or an open buffer. A field
read at query = fast. Degrade: if the gem isn't in the build, the bridge op's
mrb_module_get raises -> protect -> nil, Stage 2 is silently off.

## Method visibility model (completion)
mruby's bare-call built-ins (puts/p/print/raise/lambda/proc/loop) are Kernel
PRIVATE instance methods; `instance_methods` (public-only reflection) misses them.
Private instance-method entries are reflected via `private_instance_methods` and
stored on the index SEPARATELY (`@private_by_owner`, accessor `private_methods_of`
which unions the VM MRO) — deliberately NOT in the public method table. Result:
- explicit receiver (`x.`): public only (you cannot call a private method with an
  explicit receiver) — no private leak.
- bare / implicit self: public + `private_methods_of(owner)` (Object at top level,
  the enclosing class otherwise) — so `puts` etc. complete.
Object's OWN method table is empty in mruby (everything lives on Kernel/
BasicObject, Object just includes Kernel), so the MRO union is what surfaces
Kernel's privates for top-level bare completion.

## Outgoing range columns must be LSP code units, not bytes
Prism Location#start_column/end_column are BYTE columns. The LSP wire needs the
negotiated encoding's code units (utf-16 default). Every feature that emits a
range/position from a Prism loc uses `loc.start_code_units_column(Locator.
code_units_encoding)` (and the end variant), NOT loc.start_column — across
completion, definition, hover links, references, rename, document_highlight (incl.
its within? column compare), document_symbol, selection_range, type_hierarchy,
inlay_hint, and the buffer harvester's stored entry ranges. Semantic tokens
already used document.ast.code_units_cache. Fixtures are ASCII (byte==unit) so
this is invisible to conformance; verify on multibyte (`bar` after `"動物"` is
utf-16 col 11, byte col 15). INCOMING positions are unchanged — they still go
through Locator.position_to_byte_offset. Reflector (VM) entries have no Prism loc
(they carry a 1-based `line` only), so they are unaffected.

## document_link is out of scope (CRuby/sorbet RBI), inlay_hints is in scope
document_link in ruby-lsp ONLY linkifies `# source://gem/ver/...` and
`# pkg:gem/...` comments (tapioca/sorbet RBI artifacts) resolved to CRuby bundler
gem paths. mruby has no sorbet/RBI and no installed-gem path map, so these never
appear — returning [] is correct (same category as diagnostics/formatting).
inlay_hints, by contrast, is pure Prism AST (implicit-rescue StandardError; hash
shorthand value name + tooltip) and applies to mruby unchanged — implemented,
default ON.


A local READ resolves to the type of its nearest assignment whose write completes
before the use, searched within the enclosing LOCAL scope only. Scope boundaries
are def/class/module/singleton-class (a block is NOT a boundary — it closes over
the enclosing locals), so the search prunes nested scope subtrees. The RHS type
is inferred via `Completion.basic_type` (literal / `Foo.new` / constant) or, if
the RHS is itself a local, recursively (depth-capped against `a=b; b=a` cycles).
Wired by `Completion.receiver_type(receiver, document)` — `document` is optional,
so callers without buffer context still resolve context-free types. Every feature
that resolves a receiver (completion, definition, hover, signatureHelp) threads
`document` down to that call. Not yet inferred: method-return types, params,
ivars, multiple-assignment targets.


A class defined only in an open buffer (the VM never compiled it) has no
reflected ancestry. The harvester records its written `superclass` and bare
`include`/`prepend` names on the class Entry (new `superclass`/`mixins` fields);
`Index#ancestors` then builds the MRO: reverse(prepends) + self +
reverse(includes) + superclass chain, resolving each referenced name as VM class
(reflected MRO), buffer class (recurse), or unknown (itself), and trying the name
both as written and qualified within the class's namespace. A `visited` set
guards cyclic inheritance. VM classes keep their reflected MRO unchanged (a buffer
reopening a VM class does NOT currently alter that class's ancestry). This is what
makes inheritance + mixins work for in-buffer class trees across all features.


ruby-lsp gets multiple signatures from RBS overloads; we get them from the real
VM ancestry: every owner in `ancestors(receiver)` that defines the method is a
distinct definition with its own `Method#parameters`. `mro_methods` collects them
nearest-first (one per qualified `Owner#name`); activeSignature is 0 because the
nearest definition is the one that actually resolves. Bare calls add
`private_methods_of` (puts/p/print are Kernel privates). Receiver type for
`Foo.new` is inferred as an instance of Foo (receiver_type CallNode/`:new` case),
which also helps completion + hover. ParameterInformation labels are [start,end]
offsets into the signature label (unambiguous vs duplicate-name string labels).
Limitation: a buffer class reopening a VM class does not alter that VM class's
ancestry (rare); otherwise buffer-only hierarchies now get a computed MRO (see
the buffer-MRO note above), so overloads work for in-buffer class trees too.

## C-method param reflection can report the SIGIL as the name
mruby's C-method reflection sometimes returns the sigil itself as the param name
(rest -> "*", keyrest -> "**", block -> "&"), so naive `*#{name}` doubles it
("**", "****", "&&"). `clean_param_name` treats empty- or sigil-only names as
unnamed. (C methods also often expose generic shapes, e.g. Array#insert reflects
as 8 optionals + rest — we render the VM truth, we do not invent RBS-style names.)


`renameProvider: true` alone does NOT make clients call prepareRename. Route
`textDocument/prepareRename` -> `text_document_prepare_rename`, advertise
`renameProvider: { prepareProvider: true }`, and only return a range when the
cursor is actually ON the constant name (not merely inside the enclosing class
node) — else null. Like rename, only CONSTANTS are renameable.

## references must dedup by range
A `class Foo` definition is TWO Prism nodes at one range (the ClassNode and its
constant_path); both match the name walk. Dedup occurrences by range so each is
reported once (rename already does this via its `seen` set).


- SCREEN positions (semantic tokens, ranges, diagnostic spans): always the
  LSP-negotiated encoding (utf-16 default), computed host-side from Prism +
  code_units_cache on the BUFFER. mruby's config is irrelevant here — it only
  decides where a glyph sits on the editor's screen. (This is what the
  multibyte_characters fix addresses; it is NOT rooted in mruby.)
- mruby STRING SEMANTICS (String#length, indexing, regex/match offsets): rooted
  in mruby. Our build has MRB_UTF8_STRING OFF (default), so strings are bytes:
  "動物".length==6, "動物"[0]=="\xe5". With MRB_UTF8_STRING ON they'd be char-
  based. So any surface that reports mruby's own string measurements is
  PROJECT-CONFIG-DEPENDENT and must mirror the project's mrbconf, not host CRuby.
  We surface none today -> no current bug. If we ever do, detect the project's
  setting straight from the reflect.so (it's compiled against the project mruby):
  expose a compile-time `#ifdef MRB_UTF8_STRING` predicate (utf8_strings?) — no
  eval. Reflected NAMES already round-trip fine (C-ext tags UTF-8; symbol bytes
  are config-independent).

## Environment bootstrap (sandbox)
- No Ruby preinstalled in this sandbox image (prior images had 3.2.3). Installed
  `ruby3.2` + `ruby3.2-dev` via apt (root, no sudo). Ruby 3.2.3 — matches
  Hendrik's machine. Ruby 3.2 does NOT bundle Prism; rubygems.org is blocked.
- Prism: cloned github.com/ruby/prism, `ruby templates/template.rb` to generate
  sources, `make` (root Makefile -> build/libprism.a/.so), then
  `cd ext/prism && ruby extconf.rb && make` -> prism.so. Needed ruby3.2-dev for
  ruby.h. Prism 1.9.0.
  GOTCHA: the built ext lands at `ext/prism/prism.so`, but `lib/prism.rb` does
  `require "prism/prism"`. Either put `ext` on the load path, OR (what we did)
  copy `prism.so` into `lib/prism/prism.so` so the harness's lib-only RUBYLIB
  resolves it unchanged.
- Server boots WITHOUT the reflect .so: `Reflector.open` returns nil when
  MRUBY_REFLECT_SO is missing, so the VM layer is empty and Prism-only features
  (folding/symbol/highlight/selection/diagnostics/semantic/link/...) run fully.
  VM-backed features (hover/definition) need the reflect .so (built below).

## mruby VM + reflect.so build
- Cloned mruby master -> 4.0.0. Direct build_config (sandbox stand-in for the
  wrapper-around-user-config): `conf.gembox 'default'` (pulls the `metaprog`
  gembox, which declares `conf.gem :core => "mruby-method"`), plus
  `conf.gem github: 'Asmod4n/mruby-str-constantize', branch: 'main'` (default
  branch is `main`, NOT mruby's default `master` -> must specify), plus
  `conf.enable_debug` and `-fPIC` on cc/cxx/linker. str-constantize pulls
  mruby-c-ext-helpers (resolved via mgem-list -> Asmod4n).
- reflect.so: `MRUBY_DIR=<mruby> MRUBY_BUILD=<mruby>/build/host ruby extconf.rb
  && make`. Links the cache libmruby through g++ (str-constantize is C++).
  Loads in host Ruby, reflects the live VM (String 130 methods, upcase present,
  Integer#times -> numeric.rb:72).

## *** ALIAS source_location SEGFAULT (mruby/mruby#6879) — load-bearing ***
SYMPTOM: server segfaults at boot, in C `:source_location`, during
populate_index (reflector.rb:218 -> the .so). Dies before serving any request,
so EVERY request returns BrokenPipe. mrb_protect_error and Ruby `rescue` do NOT
catch it — it is a C-level crash.

ROOT CAUSE (mruby#6879, Asmod4n's own PR): for an ALIASED C method the alias
proc stores `body.mid` (a symbol), not `body.irep`. Method#source_location reads
it as an irep -> deref of a symbol -> SIGSEGV/SIGABRT. Reproduced on exactly 4
core alias procs: Proc#[], Proc#call, Class#new, BasicObject#!=. (cfunc_offset
returns nil for these — they are PROCS, not direct method-table cfuncs — so the
host classifies them native:false and calls source_location, hitting the bug.)

TWO TRAPS that made this confusing (both verified by running):
1. STALE GEM: declaring `conf.gem github: 'ksss/mruby-method'` pulls a 2017
   gem (commit 351d4fe) that predates aliases. mruby 4.0.0 BUNDLES a current
   `mruby-method` as a CORE mrbgem (in the metaprog gembox). Use the core one;
   do NOT declare the external ksss repo.
2. INCREMENTAL BUILD KEEPS STALE OBJECTS: after switching the gem, a plain
   `rake` left the old mruby-method objects archived in libmruby.a — still
   crashed. `rake deep_clean` + full rebuild against core mruby-method is
   REQUIRED; then source_location on the 4 returns nil, no crash.

GUARD (added — lib/mruby_lsp/reflector.rb `Reflector.alias_safe?` +
server.rb populate_index): a FORK-ISOLATED probe calls source_location on the 4
canonical alias procs in a child; if the child dies by signal, the build is
unsafe. populate_index then SKIPS the VM walk and sends window/showMessage
(type 1) telling the user to update mruby past #6879, `rake deep_clean`, and
re-run setup. Server stays up; Prism/buffer features still work. Verified both
ways: passes on a fixed build, catches a SIGSEGV-stub .so without killing the
parent, and the live server shows the message + still answers foldingRange.

## Per-feature conformance findings (LIVE run, real server + VM)
Full server booted against the vendored vectors, VM populated from the
deep_cleaned mruby 4.0.0 (alias-safe). Results:

BYTE-GREEN (4 structural features, 112 vectors) — language-structural, our
document order == ruby-lsp's:
  selection_ranges 35/35, folding_ranges 48/48, document_highlight 16/16,
  document_symbol 13/13 (+1 OOS rake).

NOT BUGS — divergence by design (different source of truth), confirmed by
reading each expectation:
  - diagnostics (5): every expectation is a RuboCop/Sorbet offense
    (fixtures literally rubocop_extension_cop, rubocop_contextual_autocorrect;
    codes like Sorbet/TrueSigil). mruby has no RuboCop/Sorbet. We return the
    correct empty pull-report {kind:"full",items:[]}.
  - document_link (2): expectations resolve `# source://` comments to BUNDLER
    gem paths (file://BUNDLER_PATH/gems/...). mruby has no Bundler gems. We
    return [].
  - definition (4): expectations reference ruby-lsp's own test classes (e.g.
    RubyLsp::ExampleClass) defined in SEPARATE, UNOPENED sibling fixtures,
    resolved by ruby-lsp's static cross-file CRuby index. Our truth is the live
    VM + open buffers; those classes are in neither -> null.
  - hover (7): expectations include language-construct prose (e.g. heredoc
    docs) and RBS content from ruby-lsp's own doc database. We have no RBS /
    keyword-doc store -> null on those.

DONE (this session — semantic_highlighting now 37/38, mirrors ruby-lsp):
  - semantic_tokens.rb rewritten to mirror ruby-lsp's SemanticHighlighting
    listener rule-for-rule: per-def/block Scope tracking ONLY parameters
    (present=:parameter, absent=:variable); local reads/writes/targets,
    block-locals, self (+defaultLibrary), numbered params, regex-capture locals;
    module->:namespace (was wrongly :class), class superclass->:class; implicit-
    self no-paren calls->:method unless special.
  - SPECIAL methods (TextMate already colors -> no token) are sourced from the
    LIVE mruby VM, NOT host CRuby: the bare-call built-ins (puts/p/print/raise/
    lambda/proc/loop) are Kernel PRIVATE instance methods and private/
    module_function are Module private, so public-only reflection missed them.
    Added a private_instance_methods op to the C bridge (OP_PRIV_IMETHODS;
    private_instance_methods is NOT a presym -> mrb_intern_lit at runtime, same
    pattern as OP_SRCLOC). Reflector.builtin_special_methods unions Kernel+Module
    public+private at populate and stashes the Set on the index (survives the
    atomic swap; empty when degraded). This visibility data is reusable for
    completion filtering + hover later.
  - UTF-16: token columns/lengths use Prism's code_units_cache built from the
    NEGOTIATED encoding (utf-8 -> bytes, utf-16 -> code units). Fixes
    multibyte_characters.
  - RANGE: response_range filters tokens by line (ruby-lsp filters purely by
    line, inclusive of start+end line, ignoring char coords). Harness sends
    semanticTokens/range for range-param fixtures.
  - The 1 remaining "fail" (special_ruby_methods) is CORRECT divergence: we
    tokenize `require` as a method because mruby has no `require`; ruby-lsp
    suppresses it (CRuby Kernel#require). Fed by our data, this is right.

NEEDS WORK (real, fed by our data — NOT divergence):
  - prepare_rename: 1/2 after fixing the harness (params is an OBJECT
    {textDocument, position}; replay_positional now reads params["position"]).
    One real fail remains to fix.

NET: live run confirms 112 byte-green; reclassifies diagnostics+document_link
(7) as out-of-scope toolchain divergence (joining rake -> 8 OOS total);
definition+hover (11) as source-of-truth divergence needing the semantic
comparator; semantic_highlighting (38) needs shape-adapt + comparator;
prepare_rename (2) needs a harness params-shape fix. ZERO failures are bugs in
mruby-lsp.

## Buffer reopenings now merge into a VM class's ancestry (boundary lifted)
Open buffers are the in-progress truth, so a buffer reopening a VM class
(adding include/prepend/superclass) now changes that class's ancestry output —
previously `Index#ancestors` short-circuited on the reflected VM MRO and ignored
buffer reopenings. `merge_buffer_mixins` splices buffer-declared modules into the
live MRO: prepend before self, include immediately after self, explicit
superclass into the chain after self; each resolved to its own ancestry and
deduped against the VM MRO.

The merge is ADDITIVE on purpose. We never subtract a compiled ancestor, because
a module in the VM MRO may come from a file that isn't open in a buffer — absence
from a buffer is not proof of removal. Consequence: a true superclass REPLACEMENT
on a class that also lives in the VM shows BOTH parents until rebuild. Clean
subtraction would need per-entry class/module tagging from the bridge (each VM MRO
slot marked class-vs-module so the superclass tail can be cut and replaced); not
worth the extra VM walking yet, and adding the new parent never hides a real
method source (safe direction). Verified by running: 8/8 logic cases (include,
prepend, both, additive-superclass, compiled-module no-op dedup, VM-only
unchanged, buffer-only unchanged) and live — completion on `"x".sh` with a buffer
`module Shout; def shout; end; end; class String; include Shout; end` returns
`shout`.

## Buffer overlay models Ruby's dynamic method table (ordered mutations)
Open buffers are the in-progress truth, so the harvester processes a class/module
body as an ORDERED sequence of method-table mutations (not a flat set of defs),
and the index reduces them over the live-VM baseline. Order matters: `def x;
undef x; def x` nets to present. Verbs handled, each with mruby's OWN observed
semantics (verified by running mruby — see test/overlay/mruby_semantics_test.rb):

- def / def self.x — add (instance/singleton), under the visibility scope
- private/protected/public — visibility scope: bare (default), `:sym` args (retro),
  inline `private def foo`
- attr_reader/writer/accessor/attr — generated accessors (`r` / `w=` / `a`+`a=`)
- alias / alias_method — new name, snapshot of the target's current signature
- define_method(:literal) — added, PUBLIC regardless of surrounding private (mruby
  diverges from CRuby here)
- module_function :name — explicit-arg only: adds a PUBLIC singleton copy, leaves
  the instance method public (no privatization); bare form is INERT in mruby
- undef / undef_method — tombstone (Entry kind :undef): blocks the name even when
  an ancestor defines it; carried through the MRO walk in visible_methods
- remove_method — own copy only (Entry kind :remove): drops the class's own copy
  and lets an inherited one reappear; NOT a tombstone; raises on a non-own method
  in mruby (we no-op)
- include / prepend — ancestry (merged into the MRO, see the boundary-lifted note)

Deliberately NOT modeled: `private_constant` (absent from mruby entirely) and
`module_function`'s bare/privatizing CRuby behavior (mruby doesn't do it). Names
computed at runtime (`define_method(var)`, `send(:undef_method, x)`) are
undecidable without eval and are skipped — there the post-build VM stays truth.

### Two traps this cornered
1. ruby-lsp is the wrong oracle for SEMANTICS. It's a cross-file union, so it
   models additions only and skips undef/remove_method/define_method and handles
   `module_function`/`private_constant`. We have a precise live-VM baseline, so we
   model deletions too — and mruby's rules (above) differ from ruby-lsp's CRuby
   ones in several places. The principle: mirror ruby-lsp's DISPLAY format, derive
   SEMANTICS from mruby.
2. `respond_to?` / bare `instance_methods` are lossy for "does this exist?" —
   they hide private methods. `module_function` first read as absent because it's
   a private Module method; it is in fact core (class.c), undef'd only on Class.
   Existence/visibility come from the method table (instance_methods ∪
   private_instance_methods + the private flag), which the C bridge reads — never
   from respond_to?.

Tests: test/overlay/buffer_overlay_test.rb (overlay logic, 13 cases),
test/overlay/mruby_semantics_test.rb (mruby behavior, 13 assertions),
test/overlay/ancestry_merge_test.rb (mixin/superclass merge).

## Class-method completion + extend (and a bug it uncovered)
`extend M` makes M's instance methods SINGLETON (class) methods of the extender.
Wiring it surfaced a pre-existing inversion: completion on a class CONSTANT
receiver (`Foo.bar`) was calling visible_methods (instance methods) — so it
offered Foo's instance methods and HID its class methods (`def self.bar` returned
nothing; `Foo.inst` wrongly listed the instance method). Fixed in completion's
call_items: a ConstantReadNode/ConstantPathNode receiver is the class OBJECT, so
it resolves CLASS methods via index.singleton_methods_for; every other receiver
(literal, Foo.new, typed local) stays the instance path.

singleton_methods_for(klass) = the class's own class methods (`def self.x` +
reflected VM singletons) walked down its BUFFER superclass chain (class methods
inherit through the superclass spine), then `extend`ed modules' instance methods
(extend self -> the module itself), then the universal Class/Module/Object/Kernel
machinery a class object answers to as an instance of Class (name, new,
instance_methods, ...). Harvester tags `extend M` / `extend self` as a class
mixin (`[:extend, name|:__self__]`); merge_buffer_mixins ignores :extend for the
instance MRO; extended_instance_methods re-presents the module's instance methods
as singletons of the extender.

Refinement deferred: inheritance of a *VM* parent's class methods. The VM gives a
flat instance MRO with no per-entry class/module tag, so the superclass spine
can't be isolated to know which compiled ancestors contribute class methods. We
walk only buffer-known superclasses; own + extended + machinery cover the rest.
Closing this needs the bridge to tag each MRO slot class-vs-module (same tag the
ancestry superclass-replacement refinement wants).

Verified: extend_singleton_test.rb (own/extended/extend-self/buffer-chain) and
live — `Foo.b`->bar, `Foo.help`->help_me (extend Helper), `Util.do`->do_it
(extend self), `Foo.i` no longer leaks the instance method, `Foo.new.in`->inst.

## class/module distinction closed both deferred refinements — with NO C change
The two deferred items both needed to tell a class from a module within a flat VM
MRO. That distinction is already reflected, so it's pure host Ruby — nothing added
to the C bridge, no new fuzz surface. `vm_class?(name)` reads the cached ancestry
the reflector already records for EVERY namespace: a class's MRO contains
BasicObject, a module's never does (verified against mruby). (`respond_to?`/kind
were dead ends — the reflector tags every namespace entry :class; the BasicObject
invariant is the real signal.)

Closed:
1. VM class-method inheritance. `superclass_spine(klass)` = buffer superclasses +
   the CLASS entries of klass's VM MRO (modules dropped via vm_class?). Class
   methods inherit down the spine, so a subclass sees a compiled parent's
   `def self.x`. (test/overlay/class_module_tag_test.rb; live: `Sub.ma`->make.)
2. Clean superclass replacement. merge_buffer_mixins now isolates klass's own
   included modules (the non-class run after self) from the old superclass spine,
   so a buffer `class Dog < Cat` over a compiled `Dog < Animal` REPLACES the spine
   (drops Animal, keeps Dog's own modules) instead of showing both parents. Falls
   back to additive when the old superclass can't be classified — never drops an
   ancestor we can't prove is the spine. (ancestry_merge_test.rb case 4.)

This was the last named soft spot. The bridge stays a dumb reflector; no C op was
added for either.

## Review fixes (Fable 5 pass)
1. `class << self` bodies were invisible to buffer harvest (regression from the
   ordered-mutation rewrite: SingletonClassNode fell to descend, which never
   emits defs). Fixed: process() handles SingletonClassNode — everything inside
   targets the SINGLETON side (defs, attr_*, alias, undef/remove, visibility,
   fresh public scope per Ruby). `class << Const` targets that constant;
   `class << obj` is a runtime value -> skipped (no eval). Singleton-side undef
   works through the existing [singleton, name]-keyed reduction. sclass_test.rb.
2. The reflector typed every VM namespace :class, so modules completed with the
   Class item kind. Fixed: record_ancestors now runs before add_class_entry and
   the entry kind comes from the BasicObject invariant (Index#vm_class?).
   Verified live: Comparable -> kind 9 (Module), String -> kind 7 (Class).

## Review notes (accepted, not fixed here)
- emit_cb (CRuby rb_ary_push) executes inside the mruby protect frame; a CRuby
  raise there (OOM-class only) would unwind across mruby's frame, skipping the
  arena restore. Probability ~0; recorded so nobody "fixes" the callback into
  doing more work inside the frame.
- The bridge's char **err plumbing is dead (run() never sets it). Kept for ABI
  stability; do not start using it without revisiting the no-bare-calls-on-error
  rule in run().
- mruby-str-constantize (external gem, the reflection floor): (uint16_t)len is
  truncated BEFORE the KEY_MAX guard, so a >=64KiB name can poison LFU eviction
  for a prefix-sharing cached key. No memory unsafety, no wrong results (the
  result cache is keyed by the full string) — cache churn only. Gem-side fix:
  guard on the mrb_int length before casting; add the case to the gem's fuzz
  corpus. Tracked in the gem repo, not here.

## Field test against a random mgem (and the bug it shook out)
Adventure run: cloned a random gem from mgem-list (mruby-murmurhash1, 2014, C),
built it into mruby 4 (default gembox + str-constantize floor + the GOTCHAS build
flags), rebuilt reflect.so against that build, ran the LSP with the gem repo as
workspace. Everything held on first contact: `Murmur` -> MurmurHash1 with the
MODULE kind, `MurmurHash1.di` -> digest (third-party C class method via live VM
singleton reflection), and go-to-definition landed in src/murmurhash1.c through
the full native pipeline (cfunc addr -> anchor offset -> addr2line).

What it caught: hover/definition/signatureHelp still had the constant-receiver
inversion the review fixed in completion — they typed `Foo` and looked up
INSTANCE methods, so a class method on a constant receiver resolved to nothing.
Fixed once in ScopeResolver.methods_for_receiver (constant receiver -> the class
object's singleton methods via singleton_methods_for; other receivers ->
instance path; unknown type -> nil so callers keep their own fallback) and wired
hover + definition through it; signatureHelp branches the same way inline.
Lesson recorded: when a receiver-side bug is found in one feature, grep every
consumer of receiver_type/receiver_method — the same decision was duplicated in
four places.

## Second client verified: mrbmacs (an editor written in mruby)
mrbmacs (masahino) is an Emacs-like editor written in mruby whose LSP client is
the pure-mruby gem mruby-lsp-client. Interop verified end-to-end in both shapes:

1. All-mruby loop: their client (compiled into an mruby 4 VM) drove mruby-lsp
   over stdio against the murmurhash adventure workspace — handshake,
   completion (`MurmurHash1.di` -> digest), hover (VM-reflected C signature),
   definition into src/murmurhash1.c, clean shutdown. Their whole dep tree
   (mruby-process2, masahino's mruby-json fork, mruby-os) built on mruby 4 head
   unmodified. mrbmacs config to use us: per-language command + args entry.

2. Self-referential session: server VM = the lspclient build itself (via the
   wrapper), workspace = the client's own repo. Their client opened its own
   mrb_lsp_client.rb: definition from a call site jumped to its own
   `def recv_message` (mrblib source_location via the wrapper's enable_debug),
   and an UNSAVED didChange adding a method to LSP::Client — the class running
   the session — hovered and resolved at its unsaved line. The buffer overlay
   works on the very class executing the request.

Process rule reaffirmed the hard way: ALL reflection deps and flags are injected
by share/wrapper_build_config.rb into the renamed parallel build — NEVER written
into a user's build config. My first lspclient build hand-rolled the floor and
broke (forgot str-constantize -> MRB_SYM(constantize) presym missing -> ext
won't compile); rebuilt through the wrapper with a byte-clean user config, the
floor injected itself and everything held. The wrapper is now field-validated on
a foreign gem's config.

Gap the session exposed + closed: hover ON a definition (DefNode) returned nil —
hover only handled call sites/constants/vars. Added a DefNode arm resolving the
def's qualified name via index.definitions (ruby-lsp parity: signature +
Definitions link + leading-comment doc). Conformance hover stayed 7/7.

## Field test 3: mruby-thread (mattn) — large C gem, multi-class
The hard case by design: 907 lines of C defining Thread/ThreadError/Queue/Mutex,
spawning real OS threads each with its own mrb_state and migrating values
between VMs via mruby internals.

Port finding (ecosystem intel, not ours): it fails to compile on mruby 4 head
only because five internal symbols it calls (mrb_mod_cv_get, mrb_mod_cv_defined,
mrb_f_global_variables, mrb_obj_instance_variables, mrb_dump_irep) moved into
mruby/internal.h. The fix is ONE line: #include <mruby/internal.h>. With it the
gem builds and runs (Thread/Queue/Mutex all functional).

LSP result: everything green first try through the wrapper build — constant
completion (Thread/ThreadError/COPY_VALUES), instance inference through the
C-defined Thread.new/Queue.new constructors (t.jo -> join, q.po -> pop), native
go-to-definition and hover on Mutex#lock into mrb_thread.c. No new bugs: the
fixes from field tests 1-2 (constant receivers, module kinds) covered this gem's
shapes. Three for three on the wrapper injecting the floor into a foreign
config.

## Field test 4: mruby-uv — largest binding in the ecosystem, C+mrblib hybrid
~5,900 lines of C (libuv bindings: 39 constants under UV — TCP/UDP/Timer/FS/
Process/Signal/TTY/...) plus pure-Ruby mrblib (UV::Yarn coroutines). Built CLEAN
on mruby 4 head through the wrapper (no patch needed, unlike mruby-thread), and
the libuv event loop genuinely ran in the smoke test.

LSP, all green in one pass: nested constant-path completion (UV::T -> TCP/TTY/
Thread/Timer/MODE_*), instance inference through C constructors (UV::Timer.new
-> start/stop), mrblib go-to-definition LINE-EXACT (UV::Yarn#resume ->
mrblib/yarn.rb:90, verified against the file), C singleton definition (UV.run ->
mrb_uv.c), hover with mrblib Definitions link. Second consecutive field test
finding zero bugs — the dynamic-overlay + receiver fixes generalize.

## First external install: two bugs the sandbox masked (and how)
1. Bare-dot completion returned NOTHING in real files. Two stacked causes:
   completionProvider advertised no triggerCharacters (so VS Code never asked
   the server at `.` — only once a word character started its own suggest), and
   Prism error recovery glues the NEXT statement's identifier in as the message
   of a bare `receiver.` (`"x".` above `puts 1` parses as `"x".puts(1)`), so the
   server filtered against an unrelated word and returned 0. Sandbox drives
   masked both: scripted clients always request explicitly (no trigger needed)
   and probe texts ended at EOF (no statement below to glue). Fix:
   triggerCharacters [".", ":", "@", "$"], and the parsed message only counts
   as the typed prefix when the CURSOR is inside the message token — otherwise
   prefix="" and the textEdit range is dropped (the debris token is on another
   line; replacing it would eat the user's code).
2. Lesson, recorded with teeth: a scripted LSP driver is not an editor. Trigger
   semantics, error-recovery parses mid-typing, and prefix/textEdit interaction
   only exist under a real client. The seam that was never exercised in-sandbox
   (bin/mruby-lsp + paths.env + setup, no hand-set env) is exactly where the
   first install broke.

## First-install root causes: locations/docs dead on C methods (+ two setup bugs)
The reported "completions but no locations, no definitions, no comments, file
only when open" reproduced EXACTLY on the never-sandbox-exercised path
(mruby-lsp-setup artifacts + bare bin/mruby-lsp, no env vars). Root cause was
ONE default: Reflector#initialize called `CLocator.open` with no argument, so
the C locator fell back to ENV["MRUBY_REFLECT_SO"] — which only the sandbox's
hand-written launchers ever set. Real launches got a nil locator: every C
method lost its file/line, definitions returned nothing, and docs vanished with
them (RDoc reads the file addr2line names). mrblib locations survived
(VM-side source_location). The setup-built artifacts were HEALTHY the whole
time — addr2line resolved string.c:3098 even under the user's -O3
-march=native. Fix: Reflector.open threads its so_path into CLocator.open.
Rule extracted: an ENV fallback that only test harnesses populate is a bug with
a delay timer. Defaults must be the production path; env vars override, never
carry.

Two more setup-path bugs found by finally running it:
1. mruby 4 lockfiles dropped the "builds" key (only mruby:{version,...}
   remains); discovery rejected every valid lock -> "build once first" forever.
   Now a parsed lock with an "mruby" section is a valid candidate (pre-4 locks
   keep the stricter builds check).
2. The wrapper intercepted only a build literally named 'host'. Any other name
   meant NO interception: the user's own build was replayed without the floor
   (constantize presym missing -> ext compile fails) and without enable_debug.
   Now it intercepts the FIRST non-internal MRuby::Build regardless of name;
   MRUBY_LSP_BASE_BUILD still pins one explicitly for multi-build configs.

Also per standing rule (NO hashing in keys): the reflect .so's version
directory is now v-<mtime-stamp> instead of v-<sha256-prefix>; require "digest"
removed from setup. Consumers read paths.env; nothing ever re-derives the dir.

## Eager startup work nobody asked for = user-visible stall
populate ran addr2line + RDoc per native method (1990 entries -> 18s sandbox,
~30s field). Nobody had asked for a single location yet. Fix: entries carry
cfunc_offset only; Index#enrich resolves file/line/doc on first hover/definition/
signatureHelp, memoized by offset (NativeResolver holds CLocator+DocExtractor,
independent of the closed VM). populate: 18.0s -> 89ms. First enrich ~117ms,
memoized ~0.01ms. Completion NEVER force-enriches -- enriching 169 items on the
first dot would reintroduce the stall; native completion items show no file hint
until something else resolves them.

Corollary (how this shipped broken twice): the bogus "fix didn't work" measurement
loaded a stale lib because `cp a/{b,c}` silently fails under sh (no brace
expansion) and the benchmark's $LOAD_PATH pointed at the unsynced canonical tree.
Sync file-by-file; point benchmarks at the tree you edited.

## Inferred type names are as-written; index names are canonical
TypeInference returns the constant as typed (`TagDSL`); index entries are
nesting-qualified (`CBOR::TagDSL`). Any consumer of an inferred name MUST
resolve it through the cursor's nesting (ScopeResolver.constant) before index
lookup, or every nested-class receiver silently completes to nothing.

## Variable entries live ONLY in the buffer layer
@entries is the VM table; ivar/cvar/gvar (and buffer constants) live in
@buffer_by_uri and surface via symbol_entries. Any new index query that scans
@entries directly will silently miss every buffer-only kind -- merge both
layers (see Index#variables).

## No MRO != class
ancestors() raises on value constants; vm_class? returns nil for them. nil must
route to :constant, never default to :class (Float::INFINITY shipped as a
"class" until completion surfaced it).

## gem install destroys mtimes; mtime-driven builds see "everything changed"
Restore them: record File.mtime per shipped file at `rake gem:build`
(share/mtimes.json), File.utime them back at setup start. Cross-platform.

## extconf + make is never a no-op
extconf rewrites the Makefile; mkmf relinks; the .so mtime moves and anything
keyed on it (v-<stamp> dirs, paths.env) churns. Guard the invocation with an
explicit is-the-output-newer-than-all-inputs check; don't rely on make.

## bundler/gem_tasks snapshots the gemspec at Rakefile load
Any task that edits version.rb before bundler's build runs is ignored -- the
spec object is already constructed. If a build must see freshly edited files,
own the task and shell out (fresh process reads fresh files).

## rescue StandardError around a constant reference hides "feature never ran"
build_c_lookup referenced MrubyCParser whose definer was never invoked; the
NameError was rescued to nil and C docs were silently absent for the project's
whole life. If a rescue guards an optional dependency, the define/require call
must be INSIDE the guarded path -- and verify the feature produces output at
least once.

## Immutable entries live in MULTIPLE index tables
Replacing an Entry with .with() in @entries does not touch the copies'
siblings in @methods_by_owner / @private_by_owner. Any bulk rewrite must hit
every table, or different features serve different versions of the same
method (hover right, completion stale).

## source_location line is a STRING -- in every consumer
Already documented for definition.rb; the doc-table lookup silently nil'd on
"54" != 54 for the project's whole life. Treat the VM's line as text at every
boundary; to_i where an Integer key is needed.

## gem install of a LOWER version does not replace the higher one
It installs alongside; require silently loads the newest. A version scheme in
a disposable tree must anchor outside the tree (recorded high-water mark),
or "freshly installed" code is silently the old gem.

## Private library APIs are version bombs
RDoc's find_body behaved differently between 6.5 and 6.14 -- silently, behind
our rescue. If a feature needs three lines of structural logic, write the
three lines; a dependency consumed through its private API is strictly worse
than no dependency.

## Gem.bindir is NOT where this gem's binstubs are
It is the default-installation bindir. User installs put binstubs in
Gem.user_dir/bin. The only authoritative source for THIS gem's location at
install time is the install path itself (derivable from __dir__ inside a
hook); record candidates and existence-check at consumption time.

## `code` is not "the editor"
codium / code-oss / code can coexist; CLI installs into the wrong one succeed
silently while the running editor never changes. Detect or let the user pin
(MRUBY_LSP_CODE); never hardcode `code`.

## Settings overrides must carry information to win
A user setting equal to the built-in fallback ("mruby-lsp") silently disabled
the entire discovery chain. Treat overrides as authoritative only when they
say something the default doesn't (path separator / existing file) -- and log
EVERY resolution branch; the one silent early-return cost an hour of
diagnosis.

## Implicit self has three shapes, not one
Explicit receiver, bare-in-class (instance self), and bare-in-`class << self`
(the class object itself). Each needs its own entry set AND ranking anchor;
treating bare as "unknown receiver" silently produces unranked completion.

## A duck-typed `visited` accumulator is a trap
resolve_ancestry's visited is a Hash; Set.new survives every code path that
never recurses into buffer classes. Probes must include the buffer layer or
the type error ships.

## "Show the redefinition chain" == "show what super can reach"
The live VM records everything super needs -- distinct MRO links with their
definitions. Anything super cannot reach (same-slot replacement) is dead and
must not be shown. Never index workspace files from disk for this; the VM is
the sole truth.

## Gem-vs-core origin: never classify by a "/mrbgems/" uri substring

Completion sub-tier ranks gem-added methods after core ones at the same ancestor
distance (the "unpack before upcase" fix). The origin signal must be an
anchored prefix check against MRUBY_ROOT (`<root>/src`, `<root>/mrblib` = core),
recorded on the Entry as `from_gem`. Do NOT infer it from `"/mrbgems/"` in the
defining uri: that only catches gems living in the mruby tree (core gems). A gem
loaded via `conf.gem path:`/`gemdir:`/`github:` has its source OUTSIDE the tree --
e.g. mruby-cbor itself at `~/code/mruby-cbor/src/` -- so a substring test
misclassifies its methods as core (sub_tier 0). It's a C-method-only problem:
Ruby methods get their real path straight from the VM's source_location.
`from_gem` is set where the real path is known (Reflector#build_method_entry for
Ruby; Index#apply_native_locations + #enrich for C, both via Origin.from_gem?).

## Setup / build environment footguns (cost real sessions)

### mruby MUST be a recent HEAD — releases up to 4.0.0 are too old
Reflection calls `Method#parameters` and `Method#source_location` on VM methods
during `Reflector#populate`. On old mruby (<= 4.0.0) these ABORT the VM (SIGABRT
in the `:parameters` CFUNC; the `source_location` variant is the separate alias
bug). It is a 7+ year bug fixed only on current master. `Reflector.alias_safe?`
guards the `source_location` alias case, but the `parameters` abort still bites
on a too-old build, so the floor is: build mruby from a recent HEAD commit, not
a tagged release. Symptom if ignored: server reflection crashes on startup with
a C-level backtrace through `:parameters`.

NOTE (2026-06-18): C-method parameters no longer route through mruby's
`:parameters` CFUNC at all — the reflect ext decodes the arg spec directly
(`params_for`/`aspec_params` in `mruby_tu.c`), both to recover true `:req`/`:opt`
(mruby reports a C method's required args as `:opt`, since its proc isn't
STRICT) and because it sidesteps that CFUNC. Ruby (irep) methods still call
`Method#parameters`, so the recent-HEAD floor stands.

### prism MUST be >= 1.9.0 — older raises NoMethodError at the first edit
Every position/range we emit goes through Prism's code-units API
(`start_code_units_column` / the `cached_*_code_units_*` variants) for correct
UTF-16 columns. That API doesn't exist on old prism — a stale prism (e.g. the
0.19 that ships as a Ruby default gem) blows up with `undefined method
start_code_units_column` the moment the buffer harvester runs. The gemspec floor
is `>= 1.9.0` and the VS Code bundle vendors exactly 1.9.0
(`editors/vscode/vendor/gems/manifest.json`); if a default/older prism shadows
it, `gem install prism -v 1.9.0` (build from the `v1.9.0` tag if rubygems is
blocked: `ruby templates/template.rb` then `gem build prism.gemspec`).

### reflect.so pairs with the value_bridge gem by ABI — install, don't $LOAD_PATH
`mruby_reflect.so` is compiled against a specific libmruby AND is driven through
the value_bridge RUBY gem. The two must be the SAME installed version. Cobbling
the Ruby side together with hand-wired `$LOAD_PATH` entries against a separately
built .so produces native crashes that look like VM bugs but are ABI mismatch.
Install the gem properly (`rake install`, which pulls value_bridge at the matched
version), then drive. Never mix a hand-pathed value_bridge with an installed .so.

### rubygems may be blocked — install deps from the vendored sources offline
The external runtime deps `prism` and `language_server-protocol` are shipped as
.gem files under `editors/vscode/vendor/gems/` (see `manifest.json`); `rbs`
(>= 3.0, now a dependency for inline-annotation parsing) is fetched there too at
package time by `rake vscode:vendor_gems` but is not committed because it has a
native ext. `value_bridge` is NOT a vendored .gem — it ships as SOURCE under
`vendor/value_bridge/` and `rake install` builds + installs it locally to satisfy
the gemspec's `add_dependency`. When rubygems.org is unreachable, install the
committed .gems with `gem install --local <file>.gem` before installing
mruby-lsp. Build prism/rbs/value_bridge exts at install time -> needs `ruby-dev`
headers present.

### value_bridge must be findable when setup builds the reflect ext
`mruby-lsp-setup` copies `ext/mruby_reflect/*` into the XDG cache and runs
`extconf.rb` there, so the in-tree relative path `../../vendor/value_bridge` no
longer resolves. extconf then needs value_bridge as an INSTALLED gem (its
`Gem::Specification.find_by_name('value_bridge')` fallback) or `VALUE_BRIDGE_DIR`
pointing at a checkout. With neither, the reflect build aborts at find_by_name.
Installing the gem (above) makes this a non-issue.

### Build the user config once before setup — discovery keys on *.rb.lock
`BuildDiscovery` globs `<workspace>/**/*.rb.lock` to find which build config the
project uses (mruby writes `#{MRUBY_CONFIG}.lock` on build). Run `rake` against
your build config once so the lock exists; otherwise setup reports `:none`
("no built config found").

### The custom/user mgem goes in the USER build_config; the wrapper adds the rest
Declare your gems (including any custom mgem) in your project's normal
build_config. Do NOT hand-roll an mruby build with your own debug/PIC/floor
flags: `wrapper_build_config.rb` replays your config verbatim into a parallel
`<base>-mruby-lsp` build and adds the reflection floor (mruby-metaprog,
mruby-method, mruby-str-constantize + its c-ext-helpers dep), `enable_debug`,
and `-fPIC` itself. Hand-building reintroduces every error the wrapper avoids
(wrong gembox -> no bin/mruby, wrong str-constantize branch, missing PIC).

### The wrapper build disables mruby's lockfile on purpose — never ship a .lock
`wrapper_build_config.rb` calls `MRuby::Lockfile.disable` at load. Two reasons,
both bugs we hit:
- **Pin freezes users.** A lock entry makes `build/load_gems.rb` reuse the
  *locked commit* instead of re-resolving `branch: 'main'` — so a shipped lock
  would freeze every user on a stale `mruby-str-constantize` and silently defeat
  branch tracking. Releases must reach users; a pin blocks that.
- **It leaks into the gem.** setup points `MRUBY_CONFIG` at the wrapper inside
  the gem (`share/wrapper_build_config.rb`), and mruby writes `<MRUBY_CONFIG>.lock`
  next to it — i.e. `share/wrapper_build_config.rb.lock`, INTO the gem/tree. Per-
  build `conf.disable_lock` is NOT enough: `Lockfile.write` (class) still emits
  the file (>= the `mruby:` block) whenever globally enabled. Only the global
  `MRuby::Lockfile.disable` makes write() a full no-op.

Scope: disable is per build *process* (our wrapper run). The user's own `rake`
(separate process, own config) keeps its `build_config.rb.lock`, which
build_discovery reads for the mruby version — do not delete it. The refresh path
is `mruby-lsp-update gems`: it clears `build/repos` so the next build re-clones
the branch HEAD. It must NOT delete the user's discovery lock (an earlier version
wrongly did, targeting `<user_config>.lock`). `.gitignore` carries `share/*.rb.lock`
as a backstop.

## setup's compile children need GEM_PATH = current ∪ Gem.default_path
`mruby-lsp-setup` shells out to two compile children: the mruby `rake` build and
the reflect extconf. The editor extension launches setup with GEM_PATH pointed at
its bundled gems (so our own requires resolve). But the extension builds that path
by prepending the bundle onto the PRIOR GEM_PATH — and when the editor itself ran
with GEM_PATH UNSET, prior is empty, so the result is a bundle-ONLY path. A non-
empty GEM_PATH overrides Ruby's compiled-in default gem dirs, so system `rake`
becomes invisible: `Gem.find_spec_for_exe: can't find gem rake`. Fix lives in
setup (Ruby knows its defaults; the TS extension can't compute them cheaply):
`BUILD_GEM_PATH = (ENV["GEM_PATH"].split(sep) + Gem.default_path + [Gem.user_dir,
Gem.dir]).uniq.join(sep)`, set on BOTH compile-child env hashes. Keeps the bundle
(value_bridge for the extconf fallback) AND restores system rake. Prepend, never
replace. LATENT until a forced clean rebuild: native-fingerprint changes (a C-code
edit) force the rebuild that invokes rake; Ruby-only updates are cache hits that
never call rake, so the bug hid until the first native change shipped.

## The return-type source is the test suite (call-seq / ISO / rbs all rejected)
Where irep and clangd can't type a method, the return type comes from the
project's own TEST SUITE — chosen after rejecting the alternatives, each for a
concrete reason (don't re-litigate):
- call-seq is RDoc PROSE, not a typed grammar. Measured on mruby: ~52% of returns
  map to a concrete class, ~36% parse-but-untyped (self/obj/unions), ~11%
  unmappable. The ecosystem runs RBS -> call-seq (RBS::RDocPlugin generates
  call-seq FROM types), never the reverse; mapping prose back to a type is
  guessing. Kept for HOVER only (clangd already surfaces it).
- ISO/IEC 30170:2012 is a 313-page PAYWALLED prose spec of a subset — not
  machine-readable signatures.
- rbs core sigs ARE typed but describe the CRuby SUPERSET, so they'd over-claim
  methods/overloads mruby lacks. Used ONLY to derive the CONTENT_ACCESSORS
  skip-list (the methods whose rbs return is the element type variable E/K/V).
The test suite is VM-true (the tests pass against the real VM), mruby-specific,
in-tree, and captures things the others fudge (IO#read's EOF-nil -> `String?`,
pinned by `assert_nil io.read(1)` at EOF). This is why the architecture is:
inline `#:`/`//:` annotation = hand-written contract (wins) > generated `.rbs`
(test-derived, per-workspace in the XDG cache) > irep/clangd inference. Each
workspace compiles its own gem set, so its test corpus -> its types.

## rbs parses the inline annotation — strip the marker, read only ClassInstance
`RBS::Parser.parse_method_type` rejects the `#:`/`//:` marker, so `extract` must
CUT the whole marker by prefix check first (converting `//` -> `#` is WRONG —
parse_method_type still chokes; remove the marker entirely). `class_name_of`
returns a name ONLY for `RBS::Types::ClassInstance` (`rt.name.to_s` ->
`"Array"`, `"::Foo::Bar"`, `"NilClass"`); void / untyped / union / singleton /
optional all yield nil — the never-guess rule, enforced by the type system
instead of by hand. `parse_method_type` is stable across rbs 2.8–4.x; the
parse-failure rescue is `RBS::ParsingError -> nil`.

## A receiver_type consumer that holds `index` must pass it
The harvested return type lives IN the index, so `Completion.receiver_type`
resolves it only when called WITH the index. Completion passed it; hover (via
`ScopeResolver.methods_for_receiver`), go-to-def (`Definition.resolve_entries`)
and signatureHelp (`SignatureHelp.resolve_overloads`) each held `index` as a
parameter but called `receiver_type(node, document)` — dropping it — so a
harvested-typed receiver resolved to nil and those features found NOTHING while
completion worked. Central `concrete_receiver` narrowing didn't help: narrow(nil)
is nil. Rule (a repeat of the constant-receiver lesson): when receiver typing
works in one feature and not another, grep EVERY `receiver_type(` call site and
check the index is threaded through — the data lives there.

## A lightweight document twin must answer every accessor the inference path reads
The buffer harvester drives return-type inference over a hand-built document
(`tdoc = Struct.new(:ast).new(Struct.new(:value).new(ast_value))`) so `infer_
return` can read `document.ast.value`. But the `#:` param path also reads
`document.ast.comments` (the annotation line above the def), and the twin's
`.ast` had no `.comments` — so opening any file with a method that calls a method
on one of its params crashed at load (`NoMethodError: undefined method 'comments'
for #<struct value=...>`). The real `Document.ast` is a `Prism::ParseResult` and
answers both; the twin must too. Fix: parse the source once in `harvest`, give
`tdoc.ast` both `.value` and `.comments`, and let `comment_lines` reuse that
parse (one parse, not two). Lesson: a stand-in document is only safe if it
answers EVERY accessor every reachable inference branch touches — the overlay
tests used a real ParseResult as `.ast`, so they never exercised the gap; a
commented real-world file did.
