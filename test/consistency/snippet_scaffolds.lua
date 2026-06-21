-- Snippet scaffolds against the REAL server. Keyword/DSL forms appear on a bare
-- prefix; block forms appear for a method that yields, with the block parameter
-- names READ FROM the method's source (its `yield`/`mrb_yield`), never guessed.
-- Real LSP client (Neovim), real mruby-HEAD VM + clangd. No mocks.
-- Run: nvim --headless -l test/consistency/snippet_scaffolds.lua

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = dir .. "?.lua;" .. package.path
local C = require("lsp_client")

C.start({
  "def walk_tree",        -- 0: a method that yields distinctively named values
  "  yield node, depth",  -- 1
  "end",                  -- 2
  "clas",                 -- 3: a bare keyword prefix
  "walk_t",               -- 4: a bare call to the yielding method
  "[1, 2, 3].dele",       -- 5: a C method (Array#delete) that mrb_yields `obj`
}, { snippets = true })

C.wait_ready(3, 4, function(r)
  local list = r and (r.items or r) or {}
  for _, it in ipairs(list) do
    if it.label == "class" and it.kind == 15 then return true end
  end
  return false
end)

local fails = 0
local function check(label, ok, got)
  C.out(("  %-46s %s"):format(label, ok and "OK" or "FAIL"))
  if not ok then C.out("      got: " .. vim.inspect(got)); fails = fails + 1 end
end

-- The snippet body for the kind-15 item labelled `name` at (line, ch), retrying
-- while the VM/clangd warm up (the C scaffold needs array.c documentSymbol'd).
local function scaffold(line, ch, name)
  local deadline = vim.loop.now() + 90000
  while true do
    local r = C.req("textDocument/completion", line, ch)
    for _, it in ipairs(r and (r.items or r) or {}) do
      if it.label == name and it.kind == 15 then
        return (it.textEdit or {}).newText or it.insertText
      end
    end
    if vim.loop.now() > deadline then return nil end
    vim.wait(1500)
  end
end

-- Keyword scaffold on a bare prefix (`clas` -> class).
local cls = scaffold(3, 4, "class")
check("`clas` -> class scaffold", cls and cls:find("class ${1:Name}", 1, true) ~= nil, cls)

-- Block scaffold, Ruby: params from `yield node, depth`.
local rb = scaffold(4, 6, "walk_tree")
check("`walk_t` -> block, params from Ruby yield", rb and rb:find("do |node, depth|", 1, true) ~= nil, rb)

-- Block scaffold, C: Array#delete mrb_yields `obj` (param read via clangd).
local c = scaffold(5, 14, "delete")
check("`.dele` -> block, param from C mrb_yield", c and c:find("do |obj|", 1, true) ~= nil, c)

C.out("")
if fails == 0 then
  C.out("PASS — scaffolds present with source-derived content")
  vim.cmd("qa!")
else
  C.out(("FAIL — %d check(s)"):format(fails))
  vim.cmd("cq")
end
