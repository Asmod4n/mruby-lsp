# value_bridge

Pass Ruby values directly between **mruby**, **CRuby**, and **JRuby** — no JSON,
CBOR, or Marshal in between.

One neutral tagged value (`vb_value`) is the interchange. Each runtime ships a
**producer** (its native value → `vb_value`) and a **consumer** (`vb_value` →
its native value). Any pair bridges by chaining one runtime's producer into
another's consumer; neither runtime ever sees the other's value type, only the
struct.

## The value

`vb_value` (see `include/vb.h`) is a tag, an origin, and a payload.

Tags: `nil`, `true`, `false`, `int` (i64), `float` (f64), `symbol`, **`utf8`**
(valid UTF-8 text), **`bytes`** (opaque bytes, no encoding promise), `bigint`
(base-10 digit string, any width), `array`, `hash` (k,v,k,v slots), `range`
(begin, end, exclusive), and **`opaque`**.

These track mruby's value-level primitives. Some are compile-guarded in mruby
(`bigint` needs `MRB_USE_BIGINT`; `float` is absent under `MRB_NO_FLOAT`) and the
legs honor the same guards. `bigint` crosses as a base-10 string so it survives
any integer width and any runtime's bignum representation. Still ride as
`opaque` for now: `Rational`, `Complex`, `Time` (mrbgem with a C API), and `Set`
(mrbgem with no extract API) -- next to be given first-class tags.

Two string tags, not one: a producer emits `utf8` only when the source string
is UTF-8/US-ASCII *and* validates; anything else (binary, other encodings) goes
out as `bytes`, verbatim. The consumer therefore never guesses an encoding and
never transcodes lossily.

Every value carries a **`from`** (`:mruby` / `:cruby` / `:jruby`) so a consumer
always knows provenance.

### Opaque — the escape hatch

A producer that meets a value outside the tag vocabulary (a `Symbol`, `Hash`,
`Rational`, a custom object, …) does **not** fail. It emits `opaque` with the
source type's `name`, the producer's raw `value` bytes, and `from`. The target
materializes a `ValueBridge::Opaque` exposing `name`, `value`, `from`.

Opaque round-trips: re-bridging an `Opaque` preserves all three fields, so the
value stays opaque and keeps its original origin across any number of hops.

(The vocabulary is deliberately minimal. Adding `Symbol`/`Hash` tags later is a
straightforward extension; until then they ride as `opaque`, lossless as to
identity and origin, lossy as to reconstruction.)

## Ownership & lifetime

A `vb_value` tree is valid only for one producer→consumer exchange. Byte spans
(`vb_span`) are **borrowed** — they point into memory the producer keeps alive
for that window (a source string in-process; an off-heap buffer across JNI). The
consumer **must** copy/materialize before returning control. `vb_free()` frees
structural memory (nodes and `array` `items[]`) only; it never touches spans.

In-process legs (mruby↔CRuby) share one address space, so strings are copied
exactly once — when the consumer builds the target string. The JRuby leg copies
once more, out of the JVM heap, because the GC may move the backing `byte[]`.
That extra copy is the only cost JRuby pays that the C legs don't.

## Layout

```
include/vb.h        neutral interchange type + contract (no Ruby/mruby deps)
src/vb.c            core: node alloc/free, UTF-8 validator, origin names
src/vb_mruby.c      mruby leg   (mruby headers only)   mrb_value <-> vb_value
cruby/vb_cruby.c    CRuby leg   (ruby.h only)          VALUE       <-> vb_value
ext/value_bridge/   CRuby extension entry + extconf.rb
lib/                CRuby/JRuby Ruby API (ValueBridge::Opaque, version)
mrblib/opaque.rb    mruby ValueBridge::Opaque
jruby/java/...      JRuby leg: IRubyObject <-> flat Node (BridgeValue, Opaque)
jruby/native/...    JNI seam between Node and vb_value
value_bridge.gemspec   rubygems (CRuby) packaging
mrbgem.rake            mgem (mruby) packaging
```

## Building each face

**rubygems / CRuby host.** Standard gem extension. Builds core + CRuby leg
always; adds the mruby leg when `mruby-config` is on `PATH` (or `MRUBY_CONFIG`
points at one), because a CRuby host bridging to an embedded mruby must link a
libmruby.

```
gem build value_bridge.gemspec
# mruby leg auto-enabled if mruby-config is found
```

**mgem / mruby host.** Add to a `build_config.rb`:

```ruby
conf.gem github: "Asmod4n/value_bridge"   # or a local path
```

Default build is core + mruby leg (always compiles). `mrbgem.rake` runs under
CRuby, so it uses `RbConfig` — the analogue of `mruby-config` — to find a
libruby. Set `VALUE_BRIDGE_CRUBY=1` to link it and add the CRuby leg, letting an
mruby tool drive an embedded CRuby VM (`ruby_init`/`ruby_cleanup`, the same API
the `ruby` CLI uses). Host-class targets only — not embedded/MCU builds.

**JRuby.** A Java extension (`jruby/java/org/valuebridge/`) flattens
`IRubyObject` to/from the same tagged shape as `vb_value`. The native handoff
(`jruby/native/vb_jni.c`) is left as an integration seam: classic JNI or
Panama/FFM, integrator's choice of JDK — both do the same mechanical copy. The
runtime-specific flatten/rebuild logic is already in `BridgeValue.java`.

## Status

Verified by building and running against real toolchains (Ruby 3.2.3, mruby
4.0.0 HEAD, JRuby 9.4.6 + OpenJDK 21):

- **Core** (`vb.c`): clean under `-Wall -Wextra` + ASan/UBSan; unit-tested.
- **CRuby leg**: compiles against real `ruby.h`; roundtrip passes for every tag
  — nil/bool/int/float, **symbol**, utf8/bytes split, **bignum** (huge ±, stays
  `Integer`), arrays, **hashes** (mixed keys, empty), **ranges** (incl/excl/
  string), nesting, and opaque (incl. origin-preserving round-trip).
- **mruby leg**: compiled into a real mruby 4.0.0 build (with `mruby-bigint`);
  same roundtrip passes, including bignum via `mruby/internal.h`
  (`mrb_bint_to_s`/`mrb_bint_new_str`). Hash/array walks freeze the source
  during iteration. A separate consumer gem bridges using only the exported
  `vb_mruby.h` — the header firewall, proven end to end.
- **JRuby leg**: producer/consumer for all tags compiles clean against JRuby
  9.4.6 + jcodings (incl. `RubyHash.visitAll`, `RubyRange`, `RubySymbol`,
  `RubyBignum`); JNI seam compiles against `jni.h`. Still **not** round-tripped —
  the native transport (`vb_jni_from_node`/`to_node`) is a declared integration
  point, not an implementation.

Strict typing throughout: producers `*_p`/`RB_TYPE_P`-check before any typed
accessor and never trust a method result's implied type; `MRB_TT_*` is keyed by
name, never by integer value (the order differs across mruby versions).

Not yet first-class (ride as `opaque`): `Rational`, `Complex` (guarded number
mrbgems), `Time` (mrbgem with C API), `Set` (mrbgem, no extract API — would go
via `to_a`). Cross-runtime composition in one process (e.g. CRuby host bridging
an embedded mruby) remains the consumer's integration.

## License

MIT. See `LICENSE`.
