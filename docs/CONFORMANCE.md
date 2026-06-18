# mruby-lsp ↔ ruby-lsp output conformance spec

Standalone mruby-lsp must produce the SAME wire output as ruby-lsp on the shared
language surface (mruby-specific content differs; STRUCTURE must not). This spec
pins each output rule to the ruby-lsp source that defines it, so every change can
be checked against the authority rather than guessed.

Authority: Shopify/ruby-lsp (cloned to /tmp/ruby-lsp-src during development).
Key files:
- lib/ruby_lsp/requests/support/common.rb
    `markdown_from_index_entries`, `categorized_markdown_from_index_entries`
- lib/ruby_lsp/listeners/hover.rb            `handle_method_hover`
- lib/ruby_indexer/lib/ruby_indexer/entry.rb `decorated_parameters`,
    `formatted_signatures`

Each rule: ID, the ruby-lsp behavior (with source), our required output, status.

---

## HOVER

### H1 — overall markdown shape
ruby-lsp (`markdown_from_index_entries`): the value is, in order, joined by blank
lines and `.chomp`ed:

    {title}

    {extra_links}        (optional, e.g. "Guessed receiver" learn-more)

    {links}              ("**Definitions**: ...")

    {documentation}      (concatenated entry comments)

Required: same order, same blank-line separation, trailing whitespace chomped.
STATUS: ☑

### H2 — title fence
ruby-lsp (`categorized_markdown_from_index_entries`):
`markdown_title = "```ruby\n#{title}\n```"`.
Required: title is a ```ruby fenced block, exactly that.
STATUS: ☑

### H3 — method title content
ruby-lsp (`handle_method_hover` + `decorated_parameters`):
`title = "#{message}#{decorated_parameters}"` then `<< formatted_signatures`.
- `decorated_parameters` → `"(#{signature.format})"`, or `"()"` when no params.
- `formatted_signatures` → "" for 1 sig; "\n(+1 overload)" for 2; "\n(+N overloads)".
Required for a method named `m`: `m(<params>)` — params ALWAYS parenthesized,
`()` when empty. (We have one signature per method, so no overload suffix.)
STATUS: ☑

### H4 — class/module title
ruby-lsp: the title is the fully-qualified constant name (no `class`/`module`
keyword prefix in the index-entry title path).
Required: bare constant name in the ```ruby block.
STATUS: ☑

### H5 — Definitions line, ALL entries
ruby-lsp: `links = "**Definitions**: " + definitions.join(" | ") + overflow`.
One link PER entry (capped by max_entries when given), joined with " | ".
Overflow: ` | N other(s)` when capped.
Required: list every resolved entry's link, joined by " | ".
STATUS: ☑

### H6 — definition link target format
ruby-lsp:
`uri = "#{entry.uri}#L#{start_line},#{start_col+1}-#{end_line},#{end_col+1}"`
`"[#{entry.file_name}](#{uri})"`.
Lines are ZERO-based internally; the link keeps them zero-based but adds 1 to
COLUMNS (note: NOT to lines). Link text is the bare file basename.
Required: `[basename](uri#Lsl,sc-el,ec)` with that column adjustment.
STATUS: ☑

### H7 — documentation
ruby-lsp: `content << "\n\n#{entry.comments}" unless entry.comments.empty?`,
concatenated across entries.
Required: append each entry's doc/comments, blank-line separated; skip empties.
STATUS: ☑

### H8 — no entries
ruby-lsp: returns nil hover when nothing resolves.
Required: `response` returns nil.
STATUS: ☑

---

## DEFINITION

### D1 — location shape
LSP `Location[]`: `{ uri, range: { start:{line,character}, end:{...} } }`.
`line`/`character` MUST be integers, line ZERO-based.
STATUS: ☑ (after the string→int + 1-based→0-based fix)

### D2 — non-navigable entries
A C builtin with only a synthetic `mruby-core://` uri is not openable; must NOT
be returned as a Location (editor raises "Unable to resolve resource").
Required: skip entries whose uri is not `file://`.
STATUS: ☑

### D3 — all matching entries
ruby-lsp returns every definition for the resolved name (e.g. a method defined in
multiple ancestors), not just the first.
STATUS: ☑ (returns all file:// entries; synthetic filtered per D2)

---

## COMPLETION

### C1 — item shape
`{ label, kind, sortText?, ... }`; kind is a `CompletionItemKind` integer.
STATUS: ☑

### C2 — kinds
METHOD=2, CLASS=7, MODULE=9, CONSTANT=21 (LSP spec; ruby-lsp uses same).
STATUS: ☑

(Completion ranking is mruby-lsp's OWN spec — scope distance — and is allowed to
differ from ruby-lsp. Only the item SHAPE conforms.)

---

## How to verify against the oracle

ruby-lsp isn't installed here (rubygems blocked); its SOURCE is the authority and
is cloned to /tmp/ruby-lsp-src. For any output rule, read the cited method and
match byte-for-byte. When ruby-lsp can be run (CI with rubygems), drive identical
input through both servers over stdio and diff hover/definition values.

---

## VERIFIED AGAINST THE RUNNING ruby-lsp SERVER

The real ruby-lsp server WAS stood up and driven over stdio (not just read from
source). Setup that makes it bootable in a no-rubygems sandbox:
- $LOAD_PATH += prism src, language_server-protocol src, ruby-lsp src
- require "bundler"; require "rbs"; require "ruby_lsp/internal"
- build RBS 4.1 from source (ruby/rbs, its C ext compiled with `extconf.rb && make`)
  and prepend its lib + ext to $LOAD_PATH. ruby-lsp requires rbs >= 3; the system
  RBS 2.8 lacks each_signature. With real RBS 4.1, ruby-lsp indexes Ruby CORE for
  real (verified: 375 core signature declarations; String#upcase hover resolves to
  string.rbs with full rdoc). NO stubbing.
- workspace needs a Gemfile so the server leaves degraded_mode
Harness: /tmp/parity/{ruby_lsp_launch.rb, ours_launch.rb, drive*.py}.

Identical input (foo.rb with `def bar(x, y = 1, *rest, key:, &blk)`), hover on the
call site, both servers:

  ruby-lsp: ```ruby
            bar(x, y = <default>, *rest, key:, &blk)
            ```
            **Definitions**: [foo.rb](file://.../foo.rb#L3,3-5,6)
  ours:     ```ruby
            bar(x, y = <default>, *rest, key:, &blk)
            ```
            **Definitions**: [foo.rb](file://.../foo.rb#L3,1-3,1)

  - title: EXACT MATCH (after fixing optional decoration `= ...` -> `= <default>`)
  - fence, Definitions label, link shape: MATCH
  - link LINE now 1-based, matching ruby-lsp (was 0-based; fixed)
  - RESOLVED: Entry now carries an optional `range` (full def..end span) and
    `name_range` (the name token), set by the buffer_harvester from Prism. Hover
    links render the full #Lsl,sc-el,ec span and definition returns the full
    targetRange + name targetSelectionRange — BYTE-IDENTICAL to ruby-lsp
    (verified: hover #L3,3-5,6; definition targetRange l2c2-l4c5, selRange
    l2c6-l2c9). VM entries without a captured range fall back to the start line.

ruby-lsp definition (verified from the running server) returns LocationLink[] with
targetRange (full def..end, 0-based) + targetSelectionRange (the name). Ours
returns Location[] with a single 0-based line. Structurally valid; range fidelity
is the same Entry-model limitation as above.

### H3a — overload suffix (verified against running ruby-lsp + real RBS 4.1)
ruby-lsp `formatted_signatures`: a method with N>1 RBS signatures appends
"\n(+N-1 overload[s])" INSIDE the ```ruby block. Verified: String#upcase hover
shows `upcase()\n(+3 overloads)` (4 RBS sigs).
mruby divergence (ALLOWED): the mruby VM exposes ONE signature per method (no RBS
overloads), so ours correctly emits no suffix. Content differs because mruby
differs from CRuby+RBS; STRUCTURE (fence, parenthesized params, suffix-on-newline
when applicable) is matched. If the VM ever reports multiple arities we follow the
same "\n(+N overloads)" rule.

### H6a — core method definition target (verified)
ruby-lsp points core methods at RBS stubs: [string.rbs](...#Lrange). Ours points
at the REAL mruby C source via addr2line: [string.c](...#Lline). Same link SHAPE;
ours resolves to actual source (mruby's correct answer), ruby-lsp to .rbs.
