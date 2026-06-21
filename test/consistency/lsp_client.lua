-- Shared real-LSP-client helper for the consistency tests. Drives the actual
-- mruby-lsp server with Neovim's built-in vim.lsp client (no mocks). One copy of
-- the boilerplate -- the very thing these tests exist to enforce.
--
-- Env honoured by callers: MRUBY_REFLECT_SO, MRUBY_LSP_WS (default /tmp/proj),
-- MRUBY_LSP_REPO (server checkout for -Ilib; default cwd), MRUBY_LSP_CLANGD.

local M = {}

M.ws   = os.getenv("MRUBY_LSP_WS") or "/tmp/proj"
M.repo = os.getenv("MRUBY_LSP_REPO") or vim.loop.cwd()
M.so   = assert(os.getenv("MRUBY_REFLECT_SO"), "set MRUBY_REFLECT_SO (from setup's paths.env)")
M.uri  = "file://" .. M.ws .. "/t.rb"

function M.out(s) io.stdout:write(s .. "\n") end
function M.fail(msg) M.out(msg); vim.cmd("cq") end

-- Write the fixture and start the server; returns client_id and bufnr with the
-- buffer attached. A trusting editor answers the unsandboxed-consent dialog
-- (Landlock is unavailable here), exactly as VS Code's trust flow would.
function M.start(lines)
  vim.fn.writefile(lines, M.ws .. "/t.rb")

  vim.lsp.handlers["window/showMessageRequest"] = function(_, result)
    if result and result.actions then
      for _, a in ipairs(result.actions) do
        if a.title == "Continue without sandbox" then return a end
      end
    end
    return vim.NIL
  end
  vim.lsp.handlers["window/showMessage"] = function() return vim.NIL end
  vim.lsp.handlers["window/logMessage"] = function() return vim.NIL end
  vim.o.swapfile = false

  local id = vim.lsp.start_client({
    name = "mruby-lsp",
    cmd = { "ruby", "-Ilib", "-r", "mruby_lsp/cli",
            "-e", "MrubyLsp::CLI.run(ARGV.shift, ARGV)", "--", "server", M.ws },
    cmd_cwd = M.repo,
    cmd_env = { MRUBY_REFLECT_SO = M.so,
                MRUBY_LSP_CLANGD = os.getenv("MRUBY_LSP_CLANGD") or "/usr/bin/clangd",
                PATH = os.getenv("PATH"), HOME = os.getenv("HOME") },
    root_dir = M.ws,
  })
  if not id then M.fail("failed to start client") end

  vim.wait(20000, function()
    local c = vim.lsp.get_client_by_id(id) ; return c ~= nil and c.initialized == true
  end, 100)
  if not vim.lsp.get_client_by_id(id) then M.fail("client died during init") end

  vim.cmd("edit " .. M.ws .. "/t.rb")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.lsp.buf_attach_client(bufnr, id)
  M.id, M.bufnr = id, bufnr
  return id, bufnr
end

-- Synchronous request at (line, ch); returns the result (or nil).
function M.req(method, line, ch, extra)
  local params = { textDocument = { uri = M.uri },
                   position = { line = line, character = ch } }
  if extra then for k, v in pairs(extra) do params[k] = v end end
  local r = vim.lsp.buf_request_sync(M.bufnr, method, params, 12000)
  return r and r[M.id] and r[M.id].result or nil
end

-- Block until `pred(result_of_a_completion_at line,ch)` is true (VM populate +
-- clangd warmup can take a while on first run).
function M.wait_ready(line, ch, pred, timeout)
  local deadline = vim.loop.now() + (timeout or 120000)
  while true do
    if pred(M.req("textDocument/completion", line, ch)) then return end
    if vim.loop.now() > deadline then M.fail("TIMEOUT waiting for server readiness") end
    vim.wait(1000)
  end
end

function M.done(failures, total, what)
  M.out("")
  if failures == 0 then
    M.out(("CONSISTENT — every endpoint agrees on %s"):format(what))
    vim.cmd("qa!")
  else
    M.out(("DIVERGENT — %d/%d %s disagree"):format(failures, total, what))
    vim.cmd("cq")
  end
end

return M
