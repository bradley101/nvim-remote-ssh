local H, T = ...
local test, eq, ok, match = H.test, H.eq, H.ok, H.match
local util = require("remote-ssh.util")

test("connects through a jump host (ProxyJump)", function()
  local conn, err = T.connect("jumped")
  ok(conn, "connect failed: " .. util.errmsg(err or ""))
  eq(conn.agent.agent, 1)
end)

test("connects through two chained jump hosts", function()
  local conn, err = T.connect("doublejump")
  ok(conn, "connect failed: " .. util.errmsg(err or ""))
end)

test("password login through askpass, with a noisy shell profile", function()
  -- The configured install directory belongs to root, so this user is asked
  -- for another one.
  T.inputs[1] = "/home/rsshpw/apps"
  local conn, err = T.connect("pw")
  ok(conn, "connect failed: " .. util.errmsg(err or ""))
  match(T.last_input_prompt, "Cannot write to")
  eq(conn.agent.base, "/home/rsshpw/apps/nvim-remote-ssh")
  eq(conn.home, "/home/rsshpw")
  local seen = false
  for _, p in ipairs(T.prompts) do
    if p:find("password", 1, true) then seen = true end
  end
  ok(seen, "no password prompt was routed through askpass")
  local res = assert(conn:call("exec", { cmd = { "id", "-un" } }))
  eq(res.stdout, "rsshpw\n")
end)

test("connection refused is reported clearly, and Cancel stops retrying", function()
  T.answers[1] = 2 -- Cancel
  local n = #T.confirms
  local conn, err = T.connect("refused")
  eq(conn, nil)
  eq(err.kind, "unreachable")
  match(err.message, "127.0.0.1:1")
  eq(#T.confirms, n + 1)
end)

test("Retry re-attempts the connection", function()
  T.answers[1], T.answers[2] = 1, 2 -- Retry, then Cancel
  local n = #T.confirms
  local _, err = T.connect("refused")
  eq(err.kind, "unreachable")
  eq(#T.confirms, n + 2)
end)

test("unresolvable host name", function()
  T.answers[1] = 2
  local _, err = T.connect("nodns")
  eq(err.kind, "dns")
  match(err.message, "does%-not%-exist%.invalid")
end)

test("a failing jump host is named in the error", function()
  T.answers[1] = 2
  local _, err = T.connect("badjump")
  ok(err)
  match(util.errmsg(err), "jump host%(s%): refused")
end)

test("invalid host names are rejected (no option injection)", function()
  local _, err = T.connect("-oProxyCommand=evil")
  eq(err.kind, "host")
end)

test("wrong password: re-prompted, then a clear auth error", function()
  local askpass = require("remote-ssh.askpass")
  local saved = askpass.handler
  local asked = 0
  askpass.handler = function(prompt)
    if prompt:find("password", 1, true) then asked = asked + 1 return "wrong" end
    return saved(prompt)
  end
  require("remote-ssh.connection").get("pw"):close()
  H.wait(function() return require("remote-ssh.connection").get("pw").state == "disconnected" end, 5000, "pw closed")
  vim.wait(700)
  T.answers[1] = 2
  local _, err = T.connect("pw")
  askpass.handler = saved
  eq(err.kind, "auth")
  ok(asked >= 2, "expected several password prompts, got " .. asked)
end)

test("changed host key is refused with instructions", function()
  local ssh = require("remote-ssh.ssh")
  local err = ssh.classify("h", "@@@@\n@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nOffending ED25519 key in /home/u/.ssh/known_hosts:3\nHost key verification failed.\n", { code = 255 })
  eq(err.kind, "hostkey_changed")
  eq(err.retryable, false)
  match(err.hint, "ssh%-keygen %-R h")
  match(err.hint, "known_hosts:3")
end)
