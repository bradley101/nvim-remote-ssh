local H, T = ...
local test, eq, ok, match = H.test, H.eq, H.ok, H.match
local util = require("remote-ssh.util")
local config = require("remote-ssh.config")
local state = require("remote-ssh.state")
local uv = vim.loop
local HTTP = os.getenv("RSSH_TEST_HTTP")

local function sources(variant, over)
  local cfg = config.get()
  cfg.remote.use_system_nvim = false
  cfg.lsp.auto_install = true
  cfg.sources = vim.tbl_deep_extend("force", {
    connectivity_url = HTTP .. "/good/",
    nvim = {
      version = "v0.0.0",
      url = HTTP .. "/" .. variant .. "/{asset}",
      checksums = HTTP .. "/" .. variant .. "/shasum.txt",
      compat_url = nil,
    },
    ripgrep = { enabled = true, version = "14.1.1", url = HTTP .. "/good/{asset}", checksums = HTTP .. "/good/{asset}.sha256" },
    mason = { version = "v2.0.1", url = HTTP .. "/good/mason.tar.gz" },
  }, over or {})
end

local function dir_for(host)
  local d = T.W .. "/remote-" .. host .. "/nvim-remote-ssh"
  state.host(host).dir = d
  return d
end

-- rg exists on this machine; hide it from the probe by pretending it is absent.
local onboard = require("remote-ssh.onboard")
local real_probe = onboard.probe
onboard.probe = function(host, dir)
  local info = real_probe(host, dir)
  if info.rg == "system" and host:match("^fresh") then info.rg = "none" end
  return info
end

test("offline server: clear error, nothing installed, no prompt", function()
  sources("good", { connectivity_url = "http://127.0.0.1:9/" })
  local d = dir_for("fresh1")
  local n = #T.confirms
  local conn, err = T.connect("fresh1")
  eq(conn, nil)
  eq(err.kind, "offline")
  match(err.message, "no internet access")
  eq(#T.confirms, n)
  eq(uv.fs_stat(d), nil)
end)

test("declining the one-time confirmation installs nothing", function()
  sources("good")
  local d = dir_for("fresh2")
  T.answers[1] = 2
  local conn, err = T.connect("fresh2")
  eq(conn, nil)
  eq(err.kind, "cancelled")
  local msg = T.confirms[#T.confirms]
  match(msg, "First%-time setup on 'fresh2' %(Linux")
  match(msg, "Neovim v0%.0%.0")
  match(msg, "ripgrep 14%.1%.1")
  match(msg, "mason%.nvim")
  eq(uv.fs_stat(d), nil)
end)

test("first connect installs everything with verified checksums; second connect is silent", function()
  sources("good")
  local d = dir_for("fresh3")
  local n = #T.confirms
  local conn, err = T.connect("fresh3")
  ok(conn, "connect failed: " .. util.errmsg(err or ""))
  eq(#T.confirms, n + 1)
  ok(uv.fs_stat(d .. "/nvim/bin/nvim"))
  ok(uv.fs_stat(d .. "/bin/rg"))
  ok(uv.fs_stat(d .. "/plugins/mason.nvim/lua/mason/init.lua"))
  eq(uv.fs_stat(d .. "/.install.lock"), nil)
  eq(vim.fn.glob(d .. "/tmp.*"), "")
  eq(conn.agent.mason, true)
  eq(assert(conn:call("which", { names = { "rg" } })).rg, d .. "/bin/rg")

  conn:close()
  H.wait(function() return conn.state == "disconnected" end, 5000, "close")
  vim.wait(700)
  n = #T.confirms
  conn, err = T.connect("fresh3")
  ok(conn, "reconnect failed: " .. util.errmsg(err or ""))
  eq(#T.confirms, n)
end)

test("checksum mismatch: refuses to install", function()
  sources("badsum")
  local d = dir_for("fresh4")
  local conn, err = T.connect("fresh4")
  eq(conn, nil)
  eq(err.kind, "install")
  match(err.message, "does not match its published checksum")
  eq(uv.fs_stat(d .. "/nvim"), nil)
  eq(uv.fs_stat(d .. "/.install.lock"), nil)
end)

test("missing checksum file: asks before installing unverified", function()
  sources("nosum")
  local d = dir_for("fresh5")
  local n = #T.confirms
  local conn, err = T.connect("fresh5")
  ok(conn, "connect failed: " .. util.errmsg(err or ""))
  eq(#T.confirms, n + 2)
  match(T.confirms[#T.confirms], "without verification")
  ok(uv.fs_stat(d .. "/nvim/bin/nvim"))
end)

test("failed download offers Retry; stale lock and leftovers are cleaned", function()
  sources("good", { nvim = { url = HTTP .. "/missing/{asset}" } })
  local d = dir_for("fresh6")
  vim.fn.mkdir(d .. "/tmp.999", "p")
  T.answers[1], T.answers[2] = 1, 2 -- Install, then Cancel the retry
  local conn, err = T.connect("fresh6")
  eq(conn, nil)
  eq(err.kind, "install")
  match(T.confirms[#T.confirms], "Download failed")
  eq(uv.fs_stat(d .. "/tmp.999"), nil)

  -- A concurrent installer holds the lock.
  sources("good")
  vim.fn.mkdir(d .. "/.install.lock", "p")
  T.answers[1] = 2 -- (consent was given already) Cancel at the "already running" prompt
  conn, err = T.connect("fresh6")
  eq(conn, nil)
  match(T.confirms[#T.confirms], "already running")
  vim.fn.delete(d .. "/.install.lock", "d")
  conn, err = T.connect("fresh6")
  ok(conn, "connect failed: " .. util.errmsg(err or ""))
end)

onboard.probe = real_probe
config.get().remote.use_system_nvim = true
config.get().lsp.auto_install = false
