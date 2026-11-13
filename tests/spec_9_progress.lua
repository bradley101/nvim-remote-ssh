local H, T = ...
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local connection = require("remote-ssh.connection")
local progress = require("remote-ssh.progress")
local launch = require("remote-ssh.launch")
local config = require("remote-ssh.config").get()

local function disconnect(host)
  local conn = connection.get(host)
  if conn and conn.state == "connected" then
    conn:close()
    wait(function() return conn.state == "disconnected" end, 5000, host .. " closed")
    vim.wait(700)
  end
end

test("a progress window follows the connection and closes when it is up", function()
  disconnect("doublejump")
  local seen, shown = {}, false
  connection.on("progress", function(host, text)
    if host == "doublejump" and text then
      seen[#seen + 1] = text
      shown = shown or (progress.visible() and progress.status().doublejump == text)
    end
  end)
  local conn, err = T.connect("doublejump")
  ok(conn, "connect failed: " .. require("remote-ssh.util").errmsg(err or ""))
  match(seen[1], "^Connecting via direct → jumped$")
  ok(shown, "the progress window was not visible while connecting")
  eq(progress.status(), {})
  eq(progress.visible(), false)
end)

test("answering a password prompt switches to 'Authenticating'", function()
  disconnect("pw")
  local seen = {}
  connection.on("progress", function(host, text)
    if host == "pw" and text then seen[#seen + 1] = text end
  end)
  local conn, err = T.connect("pw")
  ok(conn, "connect failed: " .. require("remote-ssh.util").errmsg(err or ""))
  eq(seen[1], "Connecting")
  match(seen[2], "^Authenticating as rsshpw@")
  eq(progress.visible(), false)
end)

local function password_prompts(from)
  local n = 0
  for i = from + 1, #T.prompts do
    if T.prompts[i]:find("password", 1, true) then n = n + 1 end
  end
  return n
end

test("a connected jump host is not asked for its password again", function()
  ok(connection.is_connected("pw"))
  local n = #T.prompts
  local conn, err = T.connect("behindpw")
  ok(conn, "connect failed: " .. require("remote-ssh.util").errmsg(err or ""))
  eq(password_prompts(n), 0)
  eq(assert(conn:call("exec", { cmd = { "id", "-un" } })).stdout, "root\n")
end)

test("a jump host stays connected while a host behind it is in use", function()
  -- Closing the jump host's own workspace must not cut off the host behind it.
  disconnect("pw")
  local conn = connection.get("behindpw")
  eq(assert(conn:call("exec", { cmd = { "echo", "alive" } })).stdout, "alive\n")
  eq(conn.state, "connected")
  -- ...and it is still shared: reconnecting to it needs no password.
  local n = #T.prompts
  ok(T.connect("pw"))
  eq(password_prompts(n), 0)
  -- Once nobody uses it, it is shut down and the password is needed again.
  disconnect("behindpw")
  disconnect("pw")
  n = #T.prompts
  ok(T.connect("behindpw"))
  eq(password_prompts(n), 1)
end)

test("nvim rssh-open://host/folder opens that workspace", function()
  local rs = require("remote-ssh")
  rs.workspaces.direct = nil
  vim.cmd("edit rssh-open://direct" .. vim.fn.fnameescape(T.W .. "/ws"))
  local buf = vim.api.nvim_get_current_buf()
  wait(function() return rs.workspaces.direct == T.W .. "/ws" end, 20000, "workspace opened")
  eq(vim.api.nvim_buf_is_valid(buf), false)
end)

test("the progress window is hidden while a prompt is on screen", function()
  progress.set("somehost", "Connecting")
  eq(progress.visible(), true)
  local during
  local saved = config.ui.confirm
  config.ui.confirm = function() during = progress.visible() return 1 end
  require("remote-ssh.ui").confirm("?", { "Yes" })
  config.ui.confirm = saved
  eq(during, false)
  eq(progress.visible(), true)
  progress.set("somehost", nil)
  eq(progress.visible(), false)
end)

test("open starts a separate Neovim when local files are open", function()
  local rs = require("remote-ssh")
  vim.cmd("silent! %bwipeout!")
  eq(launch.has_local_buffers(), false)
  local started = {}
  config.open.cmd = function(argv) started[#started + 1] = argv end
  -- Other hosts used by earlier tests would count as "already in use".
  local saved_ws, saved_other = rs.workspaces, launch.has_other_remote
  rs.workspaces = {}
  launch.has_other_remote = function() return false end

  -- Nothing local is open: stays here.
  eq(launch.place("unused-a", "/tmp", nil), "same")
  eq(#started, 0)

  vim.cmd("edit " .. vim.fn.fnameescape(T.W .. "/ssh_config"))
  eq(launch.has_local_buffers(), true)
  rs.open("unused-a", "/srv/my app")
  eq(#started, 1)
  eq(started[1][1], vim.v.progpath)
  eq(started[1][2], "rssh-open://unused-a/srv/my app")
  eq(connection.get("unused-a"), nil)

  -- Opted out: stays here.
  eq(launch.place("unused-a", "/tmp", { window = "same" }), "same")
  eq(#started, 1)

  -- Another remote host is in use here: its own Neovim too.
  vim.cmd("silent! %bwipeout!")
  launch.has_other_remote = saved_other
  rs.workspaces = { direct = "/tmp" }
  eq(launch.has_other_remote("unused-a"), true)
  eq(launch.place("unused-a", nil, nil), "new")
  eq(started[2][2], "rssh-open://unused-a")

  rs.workspaces = saved_ws
  config.open.cmd = nil
end)
