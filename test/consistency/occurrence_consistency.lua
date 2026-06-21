-- Cross-feature consistency, occurrence edition: "where does symbol X occur?"
-- asked three ways -- references, documentHighlight, rename. The shapes differ
-- by design (Locations / ranges / a WorkspaceEdit); the position SET must not,
-- WHERE all three are contracted to operate.
--
-- The deliberate boundary (rename.rb): rename touches CONSTANTS only (matching
-- ruby-lsp) and returns null for locals/methods, while references and
-- documentHighlight cover every identifier. So:
--   * constant -> references == documentHighlight == rename  (full agreement)
--   * local    -> references == documentHighlight, rename == null (by design)
-- Both are asserted: the agreement where it's required, AND the intentional
-- null where rename is out of scope (so a future change can't silently make
-- rename touch locals, or drop a constant, without this test noticing).
--
-- Real LSP client -> real server. Run:
--   nvim --headless -l test/consistency/occurrence_consistency.lua

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = dir .. "?.lua;" .. package.path
local C = require("lsp_client")

C.start({
  "Foo = 1",            -- 0: constant Foo (def)
  "puts Foo",           -- 1
  "puts Foo",           -- 2
  "greeting = \"hi\"",  -- 3: local greeting (def)
  "puts greeting",      -- 4
  "puts greeting",      -- 5
})
C.wait_ready(0, 0, function() return true end, 30000)
vim.wait(1500)

local function key(r) return ("%d:%d"):format(r.start.line, r.start.character) end
local function set(t)
  local seen, list = {}, {}
  for _, k in ipairs(t) do if not seen[k] then seen[k] = true; list[#list + 1] = k end end
  table.sort(list); return list
end
local function eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- The three occurrence sets at a cursor (rename set may be nil = no edit).
local function occurrences(line, ch)
  local refs = C.req("textDocument/references", line, ch,
    { context = { includeDeclaration = true } }) or {}
  local r = {} ; for _, l in ipairs(refs) do r[#r + 1] = key(l.range) end

  local hl = C.req("textDocument/documentHighlight", line, ch) or {}
  local h = {} ; for _, x in ipairs(hl) do h[#h + 1] = key(x.range) end

  local we = C.req("textDocument/rename", line, ch, { newName = "X" })
  local rn = nil
  if we and we.changes and we.changes[C.uri] then
    rn = {} ; for _, e in ipairs(we.changes[C.uri]) do rn[#rn + 1] = key(e.range) end
  end
  return set(r), set(h), rn and set(rn) or nil
end

local fails = 0
local function report(label, r, h, rn)
  C.out(label)
  C.out("    references       : " .. table.concat(r, " "))
  C.out("    documentHighlight: " .. table.concat(h, " "))
  C.out("    rename           : " .. (rn and table.concat(rn, " ") or "<null>"))
  return r, h, rn
end

-- Constant: all three must find the same set.
do
  local r, h, rn = report("constant `Foo` (rename in scope):", occurrences(0, 0))
  local ok = #r > 0 and eq(r, h) and rn ~= nil and eq(h, rn)
  C.out("    => " .. (ok and "OK (all three agree)" or "DIVERGENT"))
  if not ok then fails = fails + 1 end
end

-- Local: references and highlight agree; rename is null BY DESIGN.
do
  local r, h, rn = report("local `greeting` (rename out of scope):", occurrences(3, 3))
  local ok = #r > 0 and eq(r, h) and rn == nil
  C.out("    => " .. (ok and "OK (refs==highlight; rename null by design)" or "DIVERGENT"))
  if not ok then fails = fails + 1 end
end

C.done(fails, 2, "occurrence sets (references / documentHighlight / rename contract)")
