local H, T = ...
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local rs = require("remote-ssh")
local tree = require("remote-ssh.tree")
local connection = require("remote-ssh.connection")
local uv = vim.loop
local D = T.W .. "/ws"
vim.fn.delete(D, "rf")
vim.fn.mkdir(D .. "/lib/deep", "p")
local function put(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
put(D .. "/README.md", "# hi\n")
put(D .. "/lib/code.lua", "return 1\n")
put(D .. "/.hidden", "")

local function tree_lines()
  local buf
  for b in pairs(tree.trees) do buf = b end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
end
local function goto_line(text)
  local lines, buf = tree_lines()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) return buf end
  end
  error("tree has no line with " .. text .. ":\n" .. table.concat(lines, "\n"))
end

test("ssh config hosts are listed for the picker (patterns skipped)", function()
  local hosts = require("remote-ssh.ssh_config").hosts()
  ok(vim.tbl_contains(hosts, "direct"))
  ok(vim.tbl_contains(hosts, "jumped"))
  ok(vim.tbl_contains(hosts, "fresh6"))
  ok(not vim.tbl_contains(hosts, "*"))
  ok(not vim.tbl_contains(hosts, "unused-*"))
end)

test("open: a bad folder is re-asked, then the workspace opens with the explorer", function()
  vim.cmd("silent! only")
  T.inputs[1] = D
  rs.open("direct", D .. "/nope")
  wait(function() return rs.workspaces.direct == D end, 10000, "workspace")
  eq(rs.current, { host = "direct", root = D })
  local lines = tree_lines()
  eq(lines, { "direct:" .. D, "▸ lib/", "  .hidden", "  README.md" })
  eq(require("remote-ssh.state").recent()[1], { host = "direct", path = D })
  eq(rs.statusline(), "SSH: direct")
end)

test("explorer: expand, open, create, rename (open buffers follow), delete", function()
  local buf = goto_line("lib/")
  tree.actions.open(buf)
  eq(tree_lines(), { "direct:" .. D, "▾ lib/", "  ▸ deep/", "    code.lua", "  .hidden", "  README.md" })

  goto_line("code.lua")
  tree.actions.open(buf)
  eq(vim.api.nvim_buf_get_name(0), "rssh://direct" .. D .. "/lib/code.lua")
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "return 1" })
  local code_buf = vim.api.nvim_get_current_buf()
  ok(#vim.api.nvim_tabpage_list_wins(0) >= 2, "file opens beside the tree")

  goto_line("deep/")
  T.inputs[1] = "new/file.txt"
  tree.actions.add(buf)
  ok(uv.fs_stat(D .. "/lib/deep/new/file.txt"))
  eq(vim.api.nvim_buf_get_name(0), "rssh://direct" .. D .. "/lib/deep/new/file.txt")

  goto_line("code.lua")
  T.inputs[1] = "renamed.lua"
  tree.actions.rename(buf)
  ok(uv.fs_stat(D .. "/lib/renamed.lua"))
  eq(vim.api.nvim_buf_get_name(code_buf), "rssh://direct" .. D .. "/lib/renamed.lua")
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "return 2" })
  vim.api.nvim_buf_call(code_buf, function() vim.cmd("write") end)
  local f = io.open(D .. "/lib/renamed.lua"); eq(f:read("*a"), "return 2\n"); f:close()

  goto_line("deep/")
  T.answers[1] = 2
  tree.actions.delete(buf)
  ok(uv.fs_stat(D .. "/lib/deep"), "cancelled delete keeps the directory")
  T.answers[1] = 1
  tree.actions.delete(buf)
  eq(uv.fs_stat(D .. "/lib/deep"), nil)

  tree.actions.toggle_hidden(buf)
  ok(not vim.tbl_contains(tree_lines(), "  .hidden"))
end)

test("files / grep / symbols commands work without telescope", function()
  local picked
  local orig = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    picked = { items = items, prompt = opts.prompt }
    for _, it in ipairs(items) do
      if it == "README.md" then return cb(it) end
    end
    cb(items[1])
  end
  vim.cmd("RemoteSSH files")
  wait(function() return picked end, 10000, "file picker")
  wait(function() return vim.api.nvim_buf_get_name(0) == "rssh://direct" .. D .. "/README.md" end, 5000, "file opened")

  vim.cmd("RemoteSSH grep return")
  wait(function() return #vim.fn.getqflist() == 1 and vim.fn.getqflist({ title = 1 }).title:find("return", 1, true) end, 10000, "quickfix")
  vim.cmd("cclose")

  vim.cmd("edit rssh://direct" .. T.W .. "/proj/src/mod.lua")
  picked = nil
  vim.cmd("RemoteSSH symbols")
  wait(function() return picked end, 5000, "symbol picker")
  eq(#picked.items, 4)
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  vim.ui.select = orig

  vim.cmd("RemoteSSH outline")
  local found
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "remote-ssh-outline" then found = vim.api.nvim_buf_get_lines(b, 0, -1, false) end
  end
  eq(found, { "helper  [Function]", "M.run  [Function]", "  inner  [Function]", "M:method  [Function]" })
  vim.cmd("silent! only")
end)

test("port forwarding over the shared connection", function()
  local forward = require("remote-ssh.forward")
  eq({ forward.parse("8080") }, { "8080:localhost:8080", 8080 })
  eq({ forward.parse("8080:3000") }, { "8080:localhost:3000", 8080 })
  eq({ forward.parse("1:db:5432") }, { "1:db:5432", 1 })
  eq(forward.parse("abc"), nil)
  local conn = connection.get("direct")
  local port = tonumber((os.getenv("RSSH_TEST_HTTP") or ""):match(":(%d+)$"))
  local done
  forward.add(conn, "18765:" .. port, function(okk) done = okk end)
  wait(function() return done ~= nil end, 10000, "forward")
  eq(done, true)
  local out = vim.fn.system({ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--noproxy", "*", "http://127.0.0.1:18765/good/shasum.txt" })
  eq(out, "200")
  eq(forward.list(conn), { "18765:localhost:" .. port })
  done = nil
  forward.remove(conn, "18765:" .. port, function(okk) done = okk end)
  wait(function() return done ~= nil end, 10000, "unforward")
  eq(forward.list(conn), {})
end)

test("connection loss: edits are kept, saving is refused, auto-reconnect restores everything", function()
  put(D .. "/keep.txt", "v1\n")
  vim.cmd("edit rssh://direct" .. D .. "/keep.txt")
  local buf = vim.api.nvim_get_current_buf()
  local conn = connection.get("direct")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved work" })
  -- Kill the agent's ssh process behind the plugin's back.
  conn.proc.kill("sigkill")
  wait(function() return conn.state ~= "connected" end, 5000, "disconnect noticed")
  match(rs.statusline(), "direct %(")
  vim.cmd("write")
  eq(vim.bo[buf].modified, true)
  local f = io.open(D .. "/keep.txt"); eq(f:read("*a"), "v1\n"); f:close()
  wait(function() return conn.state == "connected" end, 20000, "auto reconnect")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "unsaved work" })
  vim.cmd("write")
  f = io.open(D .. "/keep.txt"); eq(f:read("*a"), "unsaved work\n"); f:close()
  eq(vim.bo[buf].modified, false)
end)

test("health check runs", function()
  vim.cmd("checkhealth remote-ssh")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  match(text, "OpenSSH client: OpenSSH")
  match(text, "direct: connected")
  ok(not text:find("Failed to run healthcheck", 1, true), text)
  vim.cmd("silent! bwipeout!")
end)

test("uninstall removes the install directory after confirmation", function()
  local conn = connection.get("fresh5")
  local base = conn.agent.base
  ok(uv.fs_stat(base))
  T.answers[1] = 2
  rs.uninstall("fresh5")
  vim.wait(1500)
  ok(uv.fs_stat(base), "cancel keeps it")
  T.answers[1] = 1
  rs.uninstall("fresh5")
  wait(function() return uv.fs_stat(base) == nil end, 15000, "removal")
end)
