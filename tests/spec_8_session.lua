local H, T = ...
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local rs = require("remote-ssh")
local buffer = require("remote-ssh.buffer")
local tree = require("remote-ssh.tree")
local connection = require("remote-ssh.connection")
local D = T.W .. "/sess"
vim.fn.delete(D, "rf")
vim.fn.mkdir(D .. "/src", "p")
local function put(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
put(D .. "/src/one.lua", "local a = 1\nlocal b = 2\nlocal c = 3\nreturn a\n")
put(D .. "/two.txt", "two\n")
local SESSION = T.W .. "/Session.vim"

local function wipe_all()
  vim.cmd("silent! only")
  vim.cmd("enew")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= vim.api.nvim_get_current_buf() then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
end

local function disconnect(host)
  local conn = connection.get(host)
  conn:close()
  wait(function() return conn.state == "disconnected" end, 5000, "disconnect")
  vim.wait(700)
end

test("a saved session restores remote files, cursor, workspace and explorer after reconnecting", function()
  wipe_all()
  rs.open("direct", D)
  wait(function() return rs.workspaces.direct == D end, 10000, "workspace")
  vim.cmd("wincmd p")
  vim.cmd("edit rssh://direct" .. D .. "/two.txt")
  vim.cmd("vsplit rssh://direct" .. D .. "/src/one.lua")
  vim.api.nvim_win_set_cursor(0, { 3, 4 })
  vim.cmd("mksession! " .. SESSION)
  rs.save_exit_state()

  -- "Restart": nothing connected, nothing loaded, no workspace known.
  disconnect("direct")
  wipe_all()
  rs.workspaces, rs.current = {}, nil
  eq(next(tree.trees), nil)
  require("remote-ssh.state").host("direct").tree = nil -- rely on the session's own window

  local started = vim.loop.hrtime()
  vim.cmd("source " .. SESSION)
  ok((vim.loop.hrtime() - started) / 1e6 < 1500, "loading the session must not wait for the connection")
  local one = vim.fn.bufnr("rssh://direct" .. D .. "/src/one.lua")
  ok(one > 0, "session did not restore the buffer")
  wait(function() return buffer.meta[one] end, 2000, "placeholder")
  eq(buffer.meta[one].pending, true)
  eq(vim.bo[one].modifiable, false)

  wait(function() return connection.is_connected("direct") end, 20000, "reconnect")
  wait(function() return vim.api.nvim_buf_get_lines(one, 0, 1, false)[1] == "local a = 1" end, 5000, "contents")
  eq(vim.api.nvim_buf_get_lines(one, 0, -1, false), { "local a = 1", "local b = 2", "local c = 3", "return a" })
  eq(vim.bo[one].modifiable, true)
  eq(vim.bo[one].modified, false)
  eq(vim.bo[one].filetype, "lua")
  eq(vim.api.nvim_win_get_cursor(vim.fn.bufwinid(one)), { 3, 4 })
  local two = vim.fn.bufnr("rssh://direct" .. D .. "/two.txt")
  eq(vim.api.nvim_buf_get_lines(two, 0, -1, false), { "two" })

  wait(function() return rs.workspaces.direct == D end, 5000, "workspace restored")
  eq(rs.current, { host = "direct", root = D })
  local tbuf = next(tree.trees)
  ok(tbuf and vim.fn.bufwinid(tbuf) ~= -1, "explorer was showing, so it comes back")
  eq(vim.api.nvim_buf_get_lines(tbuf, 0, 1, false), { "direct:" .. D })
  ok(vim.api.nvim_get_current_buf() ~= tbuf, "focus stays in the editing window")

  -- Restored buffers are fully functional.
  vim.api.nvim_buf_set_lines(two, 0, -1, false, { "two, edited" })
  vim.api.nvim_buf_call(two, function() vim.cmd("write") end)
  local f = io.open(D .. "/two.txt"); eq(f:read("*a"), "two, edited\n"); f:close()
end)

test("if reconnecting fails, placeholders refuse to save and load on a later reconnect", function()
  local buf = vim.fn.bufnr("rssh://direct" .. D .. "/two.txt")
  disconnect("direct")
  wipe_all()
  local config = require("remote-ssh.config").get()
  local real = config.ssh.config_file
  config.ssh.config_file = T.W .. "/does-not-exist"   -- 'direct' is now unknown
  T.answers[1] = 2
  vim.cmd("source " .. SESSION)
  buf = vim.fn.bufnr("rssh://direct" .. D .. "/two.txt")
  wait(function() return buffer.meta[buf] end, 2000, "placeholder")
  wait(function() return connection.get("direct").state == "disconnected" and connection.get("direct").last_error end, 20000, "failed connect")
  vim.wait(200)
  eq(buffer.meta[buf].pending, true)
  eq(buffer.write(buf, vim.api.nvim_buf_get_name(buf)), nil)
  local f = io.open(D .. "/two.txt"); eq(f:read("*a"), "two, edited\n"); f:close()

  config.ssh.config_file = real
  rs.reconnect("direct")
  wait(function() return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "two, edited" end, 20000, "loaded after reconnect")
end)

test("buffers restored before the plugin was listening are adopted", function()
  disconnect("direct")
  wipe_all()
  vim.cmd("noautocmd edit rssh://direct" .. D .. "/two.txt")
  local buf = vim.api.nvim_get_current_buf()
  eq(buffer.meta[buf], nil)
  vim.api.nvim_exec_autocmds("SessionLoadPost", {})
  local okk = vim.wait(20000, function() return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "two, edited" end, 10)
  if not okk then error("not adopted: " .. vim.inspect({ meta = buffer.meta[buf], state = connection.get("direct").state, err = connection.get("direct").last_error, loaded = vim.api.nvim_buf_is_loaded(buf), name = vim.api.nvim_buf_get_name(buf) })) end
  eq(vim.bo[buf].buftype, "acwrite")
end)

test("stale explorer/terminal buffer names from a session are dropped", function()
  vim.cmd("edit rssh-term://somehost/7")
  local buf = vim.api.nvim_get_current_buf()
  wait(function() return not vim.api.nvim_buf_is_valid(buf) end, 2000, "stale buffer removed")
end)
