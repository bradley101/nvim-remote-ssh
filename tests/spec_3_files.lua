local H, T = ...
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local uv = vim.loop
local buffer = require("remote-ssh.buffer")
local D = T.W .. "/files"
vim.fn.delete(D, "rf")
vim.fn.mkdir(D .. "/sub", "p")

local function put(path, data)
  local f = assert(io.open(path, "wb")); f:write(data); f:close()
end
local function get(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false) end
local function edit(path) vim.cmd("edit rssh://direct" .. path) return vim.api.nvim_get_current_buf() end

test("encode/decode round-trips line endings and missing final newline", function()
  for _, s in ipairs({ "", "a\n", "a", "a\nb\n", "a\r\nb\r\n", "a\r\nb", "a\rb\n", "\n", "\r\n", "x\r" }) do
    local l, ff, eol = buffer.decode(s)
    eq(buffer.encode(l, ff, eol), s, "round trip of " .. vim.inspect(s))
  end
  local _, ff = buffer.decode("a\r\nb\r\n")
  eq(ff, "dos")
end)

test("opens a remote file, detects filetype, saves changes atomically", function()
  put(D .. "/hello.lua", "local x = 1\nreturn x\n")
  uv.fs_chmod(D .. "/hello.lua", tonumber("750", 8))
  local buf = edit(D .. "/hello.lua")
  eq(lines(), { "local x = 1", "return x" })
  eq(vim.bo.filetype, "lua")
  eq(vim.bo.buftype, "acwrite")
  eq(vim.bo.modified, false)
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "x = x + 1" })
  vim.cmd("write")
  eq(get(D .. "/hello.lua"), "local x = 1\nx = x + 1\nreturn x\n")
  eq(vim.bo.modified, false)
  eq(uv.fs_stat(D .. "/hello.lua").mode % 4096, tonumber("750", 8), "permissions kept")
  eq(vim.fn.glob(D .. "/.*rssh*"), "", "no temp file left behind")
end)

test("keeps CRLF, a missing final newline and non-UTF-8 bytes intact", function()
  put(D .. "/dos.txt", "one\r\ntwo\r\n")
  local buf = edit(D .. "/dos.txt")
  eq(vim.bo.fileformat, "dos")
  eq(lines(), { "one", "two" })
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "three" })
  vim.cmd("write")
  eq(get(D .. "/dos.txt"), "one\r\ntwo\r\nthree\r\n")

  put(D .. "/noeol.bin", "caf\233\nlast")
  buf = edit(D .. "/noeol.bin")
  eq(vim.bo.endofline, false)
  vim.bo.fixendofline = false -- (with Vim's default 'fixeol' the newline is added, as for local files)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "top" })
  vim.cmd("write")
  eq(get(D .. "/noeol.bin"), "top\ncaf\233\nlast")
end)

test("new file in a new directory", function()
  local buf = edit(D .. "/made/up/new.txt")
  eq(lines(), { "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "created" })
  vim.cmd("write")
  eq(get(D .. "/made/up/new.txt"), "created\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "again" })
  vim.cmd("write")
  eq(get(D .. "/made/up/new.txt"), "again\n")
end)

test("writes through symlinks instead of replacing them", function()
  put(D .. "/target.txt", "t\n")
  uv.fs_symlink(D .. "/target.txt", D .. "/link.txt")
  local buf = edit(D .. "/link.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "via link" })
  vim.cmd("write")
  eq(uv.fs_lstat(D .. "/link.txt").type, "link")
  eq(get(D .. "/target.txt"), "via link\n")
end)

test("conflict: file changed on the server while edited locally", function()
  put(D .. "/c.txt", "v1\n")
  local buf = edit(D .. "/c.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
  vim.wait(20)
  put(D .. "/c.txt", "theirs\n")
  uv.fs_utime(D .. "/c.txt", os.time() + 5, os.time() + 5)

  T.answers[1] = 3 -- Cancel
  vim.cmd("write")
  match(T.confirms[#T.confirms], "changed on the server")
  eq(get(D .. "/c.txt"), "theirs\n")
  eq(vim.bo.modified, true)

  T.answers[1] = 2 -- Reload
  vim.cmd("write")
  eq(lines(), { "theirs" })
  eq(vim.bo.modified, false)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine again" })
  put(D .. "/c.txt", "theirs 2\n")
  uv.fs_utime(D .. "/c.txt", os.time() + 9, os.time() + 9)
  T.answers[1] = 1 -- Overwrite
  vim.cmd("write")
  eq(get(D .. "/c.txt"), "mine again\n")
end)

test("unmodified buffers reload when the file changes on the server", function()
  put(D .. "/w.txt", "before\n")
  local buf = edit(D .. "/w.txt")
  local conn = require("remote-ssh.connection").get("direct")
  conn:call("fs.unwatch", { path = D .. "/w.txt" })
  conn:call("fs.watch", { path = D .. "/w.txt", interval = 100 })
  put(D .. "/w.txt", "after\nmore\n")
  uv.fs_utime(D .. "/w.txt", os.time() + 3, os.time() + 3)
  wait(function() return lines(buf)[1] == "after" end, 5000, "reload")
  eq(vim.bo[buf].modified, false)
end)

test("permission errors and unreadable files do not lose data", function()
  -- As the unprivileged user: root's file is not writable/readable.
  local D = "/tmp/rssh-test-pub"
  vim.fn.mkdir(D, "p")
  uv.fs_chmod(D, tonumber("755", 8))
  put(D .. "/ro.txt", "secret\n")
  uv.fs_chmod(D .. "/ro.txt", tonumber("644", 8))
  vim.cmd("edit rssh://pw" .. D .. "/ro.txt")
  local buf = vim.api.nvim_get_current_buf()
  eq(lines(), { "secret" })
  eq(vim.bo.readonly, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hacked" })
  vim.cmd("write!")
  eq(get(D .. "/ro.txt"), "secret\n")
  eq(vim.bo.modified, true)
  vim.cmd("bwipeout!")

  uv.fs_chmod(D .. "/ro.txt", tonumber("600", 8))
  vim.cmd("edit rssh://pw" .. D .. "/ro.txt")
  eq(vim.bo.modifiable, false)
  local wrote = buffer.write(vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_name(0))
  eq(wrote, nil)
  eq(get(D .. "/ro.txt"), "secret\n")
  vim.cmd("bwipeout!")
end)

test(":write to another remote name asks before overwriting", function()
  put(D .. "/src.txt", "src\n")
  put(D .. "/dst.txt", "dst\n")
  edit(D .. "/src.txt")
  T.answers[1] = 2
  vim.cmd("write rssh://direct" .. D .. "/dst.txt")
  eq(get(D .. "/dst.txt"), "dst\n")
  vim.cmd("write rssh://direct" .. D .. "/copy.txt")
  eq(get(D .. "/copy.txt"), "src\n")
end)

test("agent file operations: list, mkdir, rename, copy, remove, find_root", function()
  local conn = require("remote-ssh.connection").get("direct")
  put(D .. "/sub/a.txt", "a")
  assert(conn:call("fs.mkdir", { path = D .. "/sub/deep/er" }))
  assert(conn:call("fs.rename", { from = D .. "/sub/a.txt", to = D .. "/sub/deep/b.txt" }))
  assert(conn:call("fs.copy", { from = D .. "/sub/deep", to = D .. "/sub/deep2" }))
  eq(get(D .. "/sub/deep2/b.txt"), "a")
  local res = assert(conn:call("fs.list", { path = D .. "/sub" }))
  eq(vim.tbl_map(function(e) return e.name .. ":" .. e.type end, res.entries), { "deep:directory", "deep2:directory" })
  local _, err = conn:call("fs.rename", { from = D .. "/sub/deep", to = D .. "/sub/deep2" })
  eq(err.code, "EEXIST")
  _, err = conn:call("fs.remove", { path = D .. "/sub/deep2" })
  ok(err, "non-recursive removal of a non-empty directory must fail")
  assert(conn:call("fs.remove", { path = D .. "/sub/deep2", recursive = true }))
  eq(uv.fs_stat(D .. "/sub/deep2"), nil)
  _, err = conn:call("fs.remove", { path = "/", recursive = true })
  eq(err.code, "EPERM")
  put(D .. "/sub/.marker", "")
  res = assert(conn:call("fs.find_root", { path = D .. "/sub/deep/er/x.c", groups = { { "nope" }, { ".marker", "other" } } }))
  eq(res.root, D .. "/sub")
  _, err = conn:call("fs.list", { path = D .. "/nonexistent" })
  eq(err.code, "ENOENT")
end)

test("large binary payloads survive the protocol", function()
  local conn = require("remote-ssh.connection").get("direct")
  local parts = {}
  for i = 0, 255 do parts[#parts + 1] = string.char(i) end
  local blob = string.rep(table.concat(parts), 20000) -- ~5 MB
  assert(conn:call("fs.write", { path = D .. "/blob.bin", data = blob }, 60000))
  eq(#get(D .. "/blob.bin"), #blob)
  local res = assert(conn:call("fs.read", { path = D .. "/blob.bin" }, 60000))
  ok(res.data == blob, "blob differs")
end)
