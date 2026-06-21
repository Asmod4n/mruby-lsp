-- Cross-feature consistency: ask the LSP the SAME thing through different
-- endpoints and require the SAME logical answer for every fact they share.
-- Formatting differs by design (a completion item vs a hover markdown blob vs a
-- Location); the FACTS behind them must not. For one method call we check:
--
--   * params — completion labelDetails.detail / hover signature / signatureHelp
--   * file   — completion labelDetails.description / hover Definitions link /
--              textDocument/definition location
--
-- params diverged for C methods (completion showed the aspec's argN placeholders
-- while hover/signatureHelp showed the real mrb_get_args names); this is the test
-- that catches that and any future drift. Real LSP client, real mruby-HEAD VM +
-- clangd. No mocks.  Run: nvim --headless -l test/consistency/feature_consistency.lua

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = dir .. "?.lua;" .. package.path
local C = require("lsp_client")

local function paren(s)
  if type(s) ~= "string" then return nil end
  local i = s:find("%(") ; local j
  for k = #s, 1, -1 do if s:sub(k, k) == ")" then j = k break end end
  if i and j and j >= i then return s:sub(i, j) end
end
local function basename(s)
  if type(s) ~= "string" then return nil end
  return (s:gsub("#.*$", ""):gsub("?.*$", ""):gsub(".*/", ""))
end

-- "abcde" receiver (6 cols), so each method name starts at column 8. Cursor
-- columns are computed PER method (names vary in length).
local scenarios = {
  { method = "index", note = "String#index (C, string.c)" },
  { method = "sub",   note = "String#sub  (Ruby, string_regexp.rb)" },
}
local BASE = 8
for _, s in ipairs(scenarios) do
  local n = #s.method
  s.comp  = BASE + n
  s.hover = BASE + math.floor(n / 2)
  s.sig   = BASE + n + 1
end
local src = {}
for _, s in ipairs(scenarios) do src[#src + 1] = ('"abcde".%s("x")'):format(s.method) end

C.start(src)
C.wait_ready(0, scenarios[1].comp, function(r)
  local list = r and (r.items or r) or {}
  for _, it in ipairs(list) do if it.label == scenarios[1].method then return true end end
  return false
end)

-- One fact, several endpoints that ALL carry it; a nil is a missing answer =
-- divergence (not silently skipped). Every value must be present AND equal.
local function check(name, list)
  local seen, val, agree, shown = false, nil, true, {}
  for _, p in ipairs(list) do
    local v = p[2]
    shown[#shown + 1] = ("%s=%s"):format(p[1], vim.inspect(v == nil and "<missing>" or v))
    if v == nil then agree = false
    elseif not seen then seen, val = true, v
    elseif v ~= val then agree = false end
  end
  local ok = seen and agree
  C.out(("    %-7s %-10s %s"):format(name, ok and "OK" or "DIVERGENT", table.concat(shown, "  ")))
  return ok
end

local failures = 0
for i, s in ipairs(scenarios) do
  local line = i - 1
  local rc = C.req("textDocument/completion", line, s.comp)
  local items = rc and (rc.items or rc) or {}
  local ci ; for _, it in ipairs(items) do if it.label == s.method then ci = it break end end
  local hov = C.req("textDocument/hover", line, s.hover)
  local hval = hov and hov.contents and (hov.contents.value or hov.contents) or ""
  local hline ; for l in tostring(hval):gmatch("[^\n]+") do if l:find("%(") then hline = l break end end
  local hfile = tostring(hval):match("%[([^%]]+)%]")
  local sg = C.req("textDocument/signatureHelp", line, s.sig)
  local sl = sg and sg.signatures and sg.signatures[1] and sg.signatures[1].label
  local df = C.req("textDocument/definition", line, s.hover)
  if df and df.uri == nil and df[1] then df = df[1] end
  local dfile = basename(df and (df.uri or df.targetUri))

  C.out(("[%d] %s"):format(i, s.note))
  local okp = check("params", {
    { "completion", ci and paren(ci.labelDetails and ci.labelDetails.detail or ci.detail) },
    { "hover", paren(hline) },
    { "signature", paren(sl) } })
  local okf = check("file", {
    { "completion", ci and (ci.labelDetails and ci.labelDetails.description) },
    { "hover", basename(hfile) },
    { "definition", dfile } })
  if not (okp and okf) then failures = failures + 1 end
end

C.done(failures, #scenarios, "every shared fact (params, file)")
