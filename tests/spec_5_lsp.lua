local H, T = ...
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local config = require("remote-ssh.config")
local lsp = require("remote-ssh.lsp")
local D = T.W .. "/lsp proj"
vim.fn.delete(D, "rf")
vim.fn.mkdir(D .. "/pkg/src", "p")
local function put(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
put(D .. "/pkg/root.marker", "")
put(D .. "/pkg/src/a.txt", "hello\nworld\n")
put(D .. "/pkg/src/other file.txt", "one\ntwo three\n")
local FAKE = vim.fn.getcwd() .. "/tests/fake_ls.py"

local function clients(buf)
  if vim.lsp.get_clients then return vim.lsp.get_clients({ bufnr = buf }) end
  return vim.lsp.get_active_clients({ bufnr = buf })
end

test("URI translation is symmetric and handles spaces and map keys", function()
  local out, inn = lsp.translators("box")
  local msg = { textDocument = { uri = "rssh://box/a b/c.lua" }, changes = { ["rssh://box/x.lua"] = { 1 } }, text = "keep rssh://other/x", empty = vim.empty_dict() }
  local wire = out(msg)
  eq(wire.textDocument.uri, "file:///a%20b/c.lua")
  eq(wire.changes["file:///x.lua"], { 1 })
  eq(wire.text, "keep rssh://other/x")
  eq(vim.json.encode(wire.empty), "{}")
  eq(msg.textDocument.uri, "rssh://box/a b/c.lua", "input must not be modified")
  eq(inn(wire).textDocument.uri, "rssh://box/a b/c.lua")
end)

test("a language server runs on the remote host with translated URIs", function()
  config.get().lsp.configs = { fakels = { cmd = { "python3", FAKE }, filetypes = { "text" }, root_markers = { "root.marker" } } }
  vim.cmd("edit rssh://direct" .. vim.fn.fnameescape(D .. "/pkg/src/a.txt"))
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo.filetype, "text")
  wait(function() return #vim.diagnostic.get(buf) > 0 end, 10000, "diagnostics from the remote server")
  local msg = vim.diagnostic.get(buf)[1].message
  -- The server saw a real file path on its own filesystem...
  match(msg, "opened file:///tmp/rssh%-test/lsp%%20proj/pkg/src/a%.txt")
  match(msg, "exists=True")
  -- ...was started in the project root found through root markers...
  match(msg, "cwd=/tmp/rssh%-test/lsp proj/pkg ")
  match(msg, "rootUri=file:///tmp/rssh%-test/lsp%%20proj/pkg ")
  -- ...and was not given our local pid.
  match(msg, "pid=None")
  eq(#clients(buf), 1)
  eq(clients(buf)[1].name, "fakels")
end)

test("go-to-definition opens another remote file", function()
  local buf = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params(0, "utf-16")
  local res = vim.lsp.buf_request_sync(buf, "textDocument/definition", params, 5000)
  local loc
  for _, r in pairs(res or {}) do loc = r.result and r.result[1] end
  ok(loc, "no definition result: " .. vim.inspect(res))
  eq(loc.uri, "rssh://direct" .. D .. "/pkg/src/other file.txt")
  vim.lsp.util.jump_to_location(loc, "utf-16")
  eq(vim.api.nvim_buf_get_name(0), "rssh://direct" .. D .. "/pkg/src/other file.txt")
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "two three" })
  eq(vim.api.nvim_win_get_cursor(0), { 2, 2 })
  -- Same server instance is reused for the second file of the project.
  wait(function() return #clients(vim.api.nvim_get_current_buf()) == 1 end, 5000, "client attached to second buffer")
  eq(clients(vim.api.nvim_get_current_buf())[1].id, clients(buf)[1].id)
end)

test("missing server without an installer: one clear warning, no crash", function()
  config.get().lsp.configs = { nols = { cmd = { "definitely-not-installed-ls" }, filetypes = { "c" } } }
  vim.cmd("edit rssh://direct" .. T.W .. "/proj/src/main.c")
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(500)
  eq(#clients(buf), 0)
end)

test("missing server is installed through mason on request, then started", function()
  config.get().lsp.auto_install = true
  config.get().lsp.configs = {
    fakels = { cmd = { "fake-language-server" }, filetypes = { "text" } },
    brokenls = { cmd = { "broken-server" }, filetypes = { "text" } },
  }
  local conn = require("remote-ssh.connection").get("fresh3")
  ok(conn and conn.state == "connected", "fresh3 should still be connected")
  local n = #T.confirms
  vim.cmd("edit rssh://fresh3" .. vim.fn.fnameescape(D .. "/pkg/src/a.txt"))
  local buf = vim.api.nvim_get_current_buf()
  wait(function() return #vim.diagnostic.get(buf) > 0 end, 15000, "diagnostics after install")
  eq(#T.confirms, n + 2) -- one question per missing server
  local seen = table.concat({ T.confirms[n + 1], T.confirms[n + 2] }, "\n")
  match(seen, "fake%-language%-server")
  match(seen, "broken%-server")
  eq(#clients(buf), 1) -- the broken one failed to install and is not retried
  local res = assert(conn:call("which", { names = { "fake-language-server" } }))
  match(res["fake-language-server"], "/mason/bin/fake%-language%-server$")

  -- Opening another file does not ask again.
  n = #T.confirms
  vim.cmd("edit rssh://fresh3" .. vim.fn.fnameescape(D .. "/pkg/src/other file.txt"))
  wait(function() return #clients(vim.api.nvim_get_current_buf()) == 1 end, 5000, "reuse")
  eq(#T.confirms, n)
  config.get().lsp.auto_install = false
  config.get().lsp.configs = {}
end)
