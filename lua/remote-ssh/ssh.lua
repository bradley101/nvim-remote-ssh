-- Everything that shells out to the system OpenSSH client.
--
-- Using the real `ssh` binary means ~/.ssh/config is honoured as-is:
-- ProxyJump / ProxyCommand chains, Include, Match, keys, agents, certificates.
-- One multiplexed (ControlMaster) connection per host is shared by all
-- operations, so authentication happens once.
local util = require("remote-ssh.util")
local proc = require("remote-ssh.proc")
local config = require("remote-ssh.config")
local uv = util.uv

local M = {}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.askpass_path = plugin_root .. "/bin/rssh-askpass"

local control_dir

--- Private directory for control sockets. Kept short: unix socket paths are
--- limited to ~104 bytes.
function M.control_dir()
  if control_dir then
    return control_dir
  end
  local uid = uv.getuid and uv.getuid() or 0
  local dir = "/tmp/rssh-" .. uid
  vim.fn.mkdir(dir, "p", tonumber("700", 8))
  local st = uv.fs_stat(dir)
  if not st or st.uid ~= uid then
    -- Somebody else owns it: fall back to a directory only we can have made.
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p", tonumber("700", 8))
  else
    uv.fs_chmod(dir, tonumber("700", 8))
  end
  control_dir = dir
  return dir
end

function M.valid_host(host)
  return type(host) == "string" and host ~= "" and not host:match("^%-") and not host:match("[%s/]")
end

--- host -> ProxyCommand that reaches it through the shared connections of
--- its jump hosts (see M.route), and the jump hosts it goes through.
local routes = {}
local hops_of = {}

--- File name of the control socket for a host alias. It does not depend on
--- how the host is reached, so every ssh we start for an alias, from any
--- Neovim, finds the same connection.
local function socket_name(host)
  return vim.fn.sha256(host .. "\n" .. (config.get().ssh.config_file or "")):sub(1, 20)
end

-- Shared connections are used by several Neovim instances, and by hosts
-- behind a jump host. Each use is recorded as an empty file next to the
-- socket, "<socket>.u.<pid>.<user>", so a connection is only shut down by
-- its last user.
local function use_file(target, by)
  return ("%s/%s.u.%d.%s"):format(M.control_dir(), socket_name(target), uv.os_getpid(), socket_name(by):sub(1, 8))
end

local function targets(host)
  local list = { host }
  vim.list_extend(list, hops_of[host] or {})
  return list
end

--- Record that `host` (and the jump hosts on the way to it) is in use here.
function M.acquire(host)
  for _, target in ipairs(targets(host)) do
    local fd = uv.fs_open(use_file(target, host), "w", tonumber("600", 8))
    if fd then
      uv.fs_close(fd)
    end
  end
end

--- Stop using `host`. Returns the aliases (host and/or its jump hosts) whose
--- shared connection nobody uses any more.
function M.release(host)
  local idle = {}
  for _, target in ipairs(targets(host)) do
    uv.fs_unlink(use_file(target, host))
    local used = false
    for _, f in ipairs(vim.fn.glob(M.control_dir() .. "/" .. socket_name(target) .. ".u.*", true, true)) do
      local pid = tonumber(f:match("%.u%.(%d+)%.[^/]*$"))
      if pid and (pid == uv.os_getpid() or uv.kill(pid, 0) == 0) then
        used = true
      else
        uv.fs_unlink(f) -- left behind by a Neovim that is gone
      end
    end
    if not used then
      idle[#idle + 1] = target
    end
  end
  return idle
end

--- Common arguments for every invocation. opts.plain leaves out the jump
--- host routing, giving what the user's ssh config alone says.
function M.base_args(host, opts)
  local c = config.get().ssh
  local tag = host and socket_name(host) or "%C"
  local a = {}
  if c.config_file then
    vim.list_extend(a, { "-F", vim.fn.expand(c.config_file) })
  end
  vim.list_extend(a, {
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" .. M.control_dir() .. "/" .. tag,
    "-o", "ControlPersist=" .. tostring(c.control_persist),
    "-o", "ConnectTimeout=" .. tostring(c.connect_timeout),
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3",
  })
  vim.list_extend(a, c.args or {})
  if host and routes[host] and not (opts and opts.plain) then
    vim.list_extend(a, { "-o", "ProxyCommand=" .. routes[host] })
  end
  return a
end

local function plain_hop(hop)
  -- Only "[user@]host" hops; ports and ssh:// URIs are left to ssh.
  return M.valid_host(hop) and not hop:find(":", 1, true)
end

--- Command that forwards stdio to %h:%p through hops[n], reaching hops[n]
--- itself through the hops before it. Every hop uses its own shared
--- connection, so one that is already open is not authenticated again.
local function proxy_command(hops, n)
  local parts = { util.shq(M.cmd()) }
  local args = M.base_args(hops[n], { plain = true })
  -- hops[1] has no jump hosts of its own (M.route expanded them).
  if n > 1 then
    vim.list_extend(args, { "-o", "ProxyCommand=" .. proxy_command(hops, n - 1) })
  end
  for _, arg in ipairs(args) do
    -- This string is expanded once more (%h, %p) by the ssh that runs it.
    parts[#parts + 1] = util.shq((arg:gsub("%%", "%%%%")))
  end
  vim.list_extend(parts, { "-W", "'[%h]:%p'", "--", util.shq(hops[n]) })
  return table.concat(parts, " ")
end

--- Given a host's effective config: when it is reached through jump hosts,
--- go through them with our own shared connections. A jump host that is
--- already connected (it is open as a workspace, or another host behind it
--- is) is not authenticated again; one connected now is kept for the next
--- host behind it. cb() when done.
function M.route(host, effective, cb)
  routes[host], hops_of[host] = nil, nil
  local jump = effective and effective.proxyjump
  if not config.get().ssh.share_jump_hosts or not jump or jump == "" or jump == "none" then
    return cb()
  end
  local hops = {}
  for _, hop in ipairs(vim.split(jump, ",", { plain = true, trimempty = true })) do
    hops[#hops + 1] = vim.trim(hop)
  end
  -- The first hop may itself be behind jump hosts in the user's config.
  local function expand(depth)
    for _, hop in ipairs(hops) do
      if not plain_hop(hop) then
        return cb()
      end
    end
    if depth > 8 then
      return cb()
    end
    M.effective_config(hops[1], function(eff)
      local j = eff.proxyjump
      if j and j ~= "" and j ~= "none" then
        local before = vim.split(j, ",", { plain = true, trimempty = true })
        for i = #before, 1, -1 do
          table.insert(hops, 1, vim.trim(before[i]))
        end
        return expand(depth + 1)
      end
      routes[host] = proxy_command(hops, #hops)
      hops_of[host] = hops
      cb()
    end)
  end
  expand(1)
end

--- Environment that routes every ssh prompt (password, passphrase, OTP,
--- host key confirmation) into this Neovim instance.
function M.env()
  local server = vim.v.servername
  if server == nil or server == "" then
    server = vim.fn.serverstart()
  end
  return {
    SSH_ASKPASS = M.askpass_path,
    SSH_ASKPASS_REQUIRE = "force",
    -- Older OpenSSH only consults SSH_ASKPASS when DISPLAY is set.
    DISPLAY = os.getenv("DISPLAY") or ":0",
    RSSH_NVIM = vim.v.progpath,
    RSSH_SERVER = server,
  }
end

function M.cmd()
  return config.get().ssh.cmd
end

--- Run `remote_cmd` (a single string interpreted by the remote login shell)
--- on host. cb({code, stdout, stderr, ...}).
function M.exec(host, remote_cmd, opts, cb)
  opts = opts or {}
  local args = M.base_args(host)
  vim.list_extend(args, opts.ssh_args or {})
  vim.list_extend(args, { "--", host })
  if remote_cmd then
    args[#args + 1] = remote_cmd
  end
  return proc.run(M.cmd(), args, {
    env = M.env(),
    stdin = opts.stdin,
    timeout = opts.timeout,
    on_stdout = opts.on_stdout,
  }, cb)
end

M.BEGIN = "RSSH_BEGIN_4f1c"
M.END = "RSSH_END_4f1c"

--- Run a POSIX sh script on the host. The script travels over stdin, so it
--- works regardless of the user's login shell (fish, csh, ...), and its
--- output is fenced with sentinels so noise printed by shell startup files
--- is ignored. cb(result) with result.body = fenced output (nil if the
--- sentinels never appeared).
function M.script(host, script, opts, cb)
  local wrapped = table.concat({
    "echo " .. M.BEGIN,
    script,
    "echo",
    "echo " .. M.END,
    "",
  }, "\n")
  opts = vim.tbl_extend("force", { stdin = wrapped }, opts or {})
  return M.exec(host, "sh", opts, function(res)
    local s = res.stdout:find(M.BEGIN, 1, true)
    if s then
      local e = res.stdout:find(M.END, s, true)
      if e then
        res.body = res.stdout:sub(s + #M.BEGIN + 1, e - 1)
        res.noise = res.stdout:sub(1, s - 1)
      end
    end
    cb(res)
  end)
end

--- Send a control command (-O check|exit|forward|cancel) to the shared
--- connection.
function M.control(host, op, extra, cb)
  local args = M.base_args(host)
  vim.list_extend(args, { "-O", op })
  vim.list_extend(args, extra or {})
  vim.list_extend(args, { "--", host })
  return proc.run(M.cmd(), args, { env = M.env(), timeout = 10000 }, cb)
end

--- Effective configuration for a host (`ssh -G`), as a map of lowercase keys.
function M.effective_config(host, cb)
  local args = M.base_args(host, { plain = true })
  vim.list_extend(args, { "-G", "--", host })
  proc.run(M.cmd(), args, { timeout = 10000 }, function(res)
    local map = {}
    if res.code == 0 then
      for line in res.stdout:gmatch("[^\n]+") do
        local k, v = line:match("^(%S+)%s+(.*)$")
        if k and not map[k] then
          map[k] = v
        end
      end
    end
    cb(map)
  end)
end

--- Turn ssh's stderr into a structured, user-readable error.
function M.classify(host, stderr, res)
  stderr = stderr or ""
  local raw = util.tail(stderr, 4)
  local function e(kind, msg, hint, retry)
    local err = util.err(kind, msg, hint)
    err.retryable = retry or false
    err.raw = raw
    return err
  end

  if res and res.spawn_failed then
    return e(
      "no_ssh",
      ("Could not run '%s': %s"):format(M.cmd(), stderr),
      "Install the OpenSSH client (e.g. `apt install openssh-client`, `brew install openssh`) or set ssh.cmd."
    )
  end
  if stderr:find("REMOTE HOST IDENTIFICATION HAS CHANGED", 1, true) then
    local file = stderr:match("Offending [%w%-]+ key in ([^\r\n]+)")
    return e(
      "hostkey_changed",
      ("The host key of '%s' has CHANGED. This can mean the server was reinstalled, or that someone is intercepting the connection. Not connecting."):format(host),
      ("If you are certain the change is legitimate, remove the old key and reconnect:\n  ssh-keygen -R %s%s"):format(
        host,
        file and ("\n(offending entry: " .. file .. ")") or ""
      )
    )
  end
  if stderr:find("Host key verification failed", 1, true) then
    return e("hostkey_rejected", ("Host key for '%s' was not accepted; not connecting."):format(host), nil, true)
  end
  if stderr:find("Too many authentication failures", 1, true) then
    return e(
      "auth",
      ("Authentication to '%s' failed: too many keys were offered."):format(host),
      "Set `IdentitiesOnly yes` and an explicit `IdentityFile` for this host in your ssh config.",
      true
    )
  end
  if stderr:find("Permission denied", 1, true) then
    local methods = stderr:match("Permission denied %(([^)]+)%)")
    return e(
      "auth",
      ("Authentication to '%s' failed%s."):format(host, methods and (" (server accepts: " .. methods .. ")") or ""),
      "Check the user name, key or password for this host.",
      true
    )
  end
  local unresolved = stderr:match("Could not resolve hostname ([^:%s]+)")
  if unresolved then
    return e("dns", ("Could not resolve host name '%s'."):format(unresolved), "Check the HostName in your ssh config and your network/VPN.", true)
  end
  local target, port, why = stderr:match("connect to host (%S+) port (%d+): ([^\r\n]+)")
  if target then
    return e("unreachable", ("Could not reach %s:%s: %s"):format(target, port, why), "Check that the host is up and reachable (VPN, firewall, port).", true)
  end
  if stderr:find("timed out", 1, true) then
    return e("timeout", ("Connection to '%s' timed out."):format(host), "Check that the host is reachable (VPN, firewall).", true)
  end
  if
    stderr:find("kex_exchange_identification", 1, true)
    or stderr:find("UNKNOWN port 65535", 1, true)
    or stderr:find("stdio forwarding failed", 1, true)
    or stderr:find("open failed", 1, true)
  then
    return e(
      "proxy",
      ("Connection to '%s' was closed while going through a proxy or jump host."):format(host),
      "The jump host could not open a connection to the target. Check ProxyJump/ProxyCommand and that the target is reachable from the jump host.",
      true
    )
  end
  if stderr:find("Bad owner or permissions", 1, true) or stderr:find("Bad configuration option", 1, true) or stderr:find("terminating, %d+ bad configuration") then
    return e("config", "Your ssh configuration has a problem:\n" .. raw, "Fix the file mentioned above and try again.")
  end
  if res and res.timed_out then
    return e("timeout", ("Connection to '%s' timed out."):format(host), nil, true)
  end
  return e("ssh", ("ssh to '%s' failed%s"):format(host, raw ~= "" and (":\n" .. raw) or (" (exit code " .. tostring(res and res.code) .. ")")), nil, true)
end

--- Annotate an error with the jump chain when one is configured, so the user
--- can tell which hop to look at.
function M.annotate_jump(err, effective)
  local jump = effective and effective.proxyjump
  if jump and jump ~= "" and jump ~= "none" and err.kind ~= "hostkey_changed" then
    local note = "This host is reached through jump host(s): " .. jump
    err.hint = err.hint and (err.hint .. "\n" .. note) or note
  elseif effective and effective.proxycommand and effective.proxycommand ~= "none" then
    local note = "This host is reached through ProxyCommand: " .. effective.proxycommand
    err.hint = err.hint and (err.hint .. "\n" .. note) or note
  end
  return err
end

return M
