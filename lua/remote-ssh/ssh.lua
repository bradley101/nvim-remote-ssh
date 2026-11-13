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

--- host -> ProxyCommand that reaches it through the shared connection of
--- its jump host (see M.route).
local routes = {}

--- Common arguments for every invocation. opts.plain leaves out the jump
--- host routing, giving what the user's ssh config alone says.
function M.base_args(host, opts)
  local c = config.get().ssh
  -- The alias is part of the socket name so two aliases of one server do not
  -- share (and close) each other's connection.
  local tag = host and (vim.fn.sha256(host):sub(1, 10) .. "-") or ""
  local a = {}
  if c.config_file then
    vim.list_extend(a, { "-F", vim.fn.expand(c.config_file) })
  end
  vim.list_extend(a, {
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" .. M.control_dir() .. "/" .. tag .. "%C",
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

--- Given a host's effective config: when it is reached through jump hosts,
--- go through the last one with our own shared connection to it. If that
--- jump host is already connected (it is open as a workspace, or another
--- host behind it is), nothing has to be authenticated again; otherwise the
--- connection made now is kept for the next host behind it.
function M.route(host, effective)
  routes[host] = nil
  local jump = effective and effective.proxyjump
  if not config.get().ssh.share_jump_hosts or not jump or jump == "" or jump == "none" then
    return
  end
  local hops = vim.split(jump, ",", { plain = true, trimempty = true })
  local last = vim.trim(hops[#hops] or "")
  -- Only plain "[user@]host" hops; ports and ssh:// URIs are left to ssh.
  if not M.valid_host(last) or last:find(":", 1, true) then
    return
  end
  local parts = { util.shq(M.cmd()) }
  for _, arg in ipairs(M.base_args(last, { plain = true })) do
    parts[#parts + 1] = util.shq((arg:gsub("%%", "%%%%")))
  end
  if #hops > 1 then
    hops[#hops] = nil
    parts[#parts + 1] = "-J"
    parts[#parts + 1] = util.shq((table.concat(hops, ","):gsub("%%", "%%%%")))
  end
  vim.list_extend(parts, { "-W", "'[%h]:%p'", "--", util.shq(last) })
  routes[host] = table.concat(parts, " ")
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
