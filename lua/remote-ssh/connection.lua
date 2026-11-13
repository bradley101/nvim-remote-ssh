-- One Conn per host: the shared ssh connection, the remote agent and
-- everything multiplexed over it.
local util = require("remote-ssh.util")
local ssh = require("remote-ssh.ssh")
local proc = require("remote-ssh.proc")
local rpc = require("remote-ssh.rpc")
local config = require("remote-ssh.config")
local onboard = require("remote-ssh.onboard")
local ui = require("remote-ssh.ui")
local log = require("remote-ssh.log")
local state = require("remote-ssh.state")

local await, shq, uv = util.await, util.shq, util.uv

local M = {}

M.conns = {}
local hooks = { connected = {}, disconnected = {}, progress = {} }

--- Subscribe to "connected"(conn), "disconnected"(conn) or
--- "progress"(host, text|nil).
function M.on(event, fn)
  table.insert(hooks[event], fn)
end

local function fire(event, ...)
  for _, fn in ipairs(hooks[event]) do
    local ok, err = pcall(fn, ...)
    if not ok then
      log.debug(event .. " hook failed: " .. tostring(err))
    end
  end
end

local AGENT_SENTINEL = "RSSH_AGENT_START_9d2e"

local Conn = {}
Conn.__index = Conn

function M.get(host)
  return M.conns[host]
end

function M.is_connected(host)
  local c = M.conns[host]
  return c ~= nil and c.state == "connected"
end

local function progress(conn, text)
  conn.status = text
  if not conn.quiet or not text then
    require("remote-ssh.progress").set(conn.host, text)
  end
  if text then
    log.debug(("[%s] %s"):format(conn.host, text))
  end
  fire("progress", conn.host, text)
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
  end)
end

--- Called after the user answered an ssh prompt (password, passphrase,
--- one-time code, host key): the connection attempts that are still at the
--- login stage are now authenticating.
function M.answered(prompt)
  local who = prompt:match("^%s*%(?([^%s()']+@[^%s()':]+)%)?'s [Pp]assword") or prompt:match("^%s*%(([^%s()]+@[^%s()]+)%)")
  for _, conn in pairs(M.conns) do
    if conn.state == "connecting" and conn.stage == "login" then
      progress(conn, who and ("Authenticating as " .. who) or "Authenticating")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Establishing a connection (runs inside a coroutine)
-- ---------------------------------------------------------------------------

--- Authenticate and open the shared connection.
local function open_master(conn)
  local host = conn.host
  local mux_retry = false
  -- Name the jump hosts: they are what makes a connection slow.
  local eff = await(function(cb)
    ssh.effective_config(host, cb)
  end)
  local jump = eff.proxyjump
  local via = jump and jump ~= "" and jump ~= "none" and (" via " .. jump:gsub(",%s*", " → ")) or ""
  while true do
    conn.stage = "login"
    progress(conn, "Connecting" .. via)
    local res = await(function(cb)
      ssh.exec(host, "echo RSSH_CONNECTED", {}, cb)
    end)
    conn.stage = nil
    if res.code == 0 and res.stdout:find("RSSH_CONNECTED", 1, true) then
      return
    end
    log.debug(("[%s] ssh failed (%s): %s"):format(host, tostring(res.code), util.tail(res.stderr, 8)))

    -- A broken control socket: drop it and try again, once, silently.
    if not mux_retry and (res.stderr:find("mux_client", 1, true) or res.stderr:find("Control socket", 1, true) or res.stderr:find("ControlSocket", 1, true)) then
      mux_retry = true
      await(function(cb)
        ssh.control(host, "exit", nil, cb)
      end)
    else
      local err
      if res.code == 0 then
        err = util.err(
          "probe",
          ("Connected to '%s', but the server did not run commands as expected."):format(host),
          "The account may have a restricted shell or a forced command.\n" .. util.tail(res.stdout .. res.stderr, 4)
        )
      else
        err = ssh.classify(host, res.stderr, res)
        ssh.annotate_jump(err, eff)
      end
      if not err.retryable or conn.quiet then
        error(err)
      end
      local choice = ui.confirm(util.errmsg(err), { "Retry", "Cancel" })
      if choice ~= 1 then
        err.reported = true
        error(err)
      end
    end
  end
end

--- Probe, plan, (consent, install) until the server is ready. Returns the
--- probe info and the path of the nvim to run the agent with.
local function prepare_server(conn)
  local host = conn.host
  local dir = state.host(host).dir or config.get().remote.dir
  local unverified_net = true
  while true do
    progress(conn, "Inspecting server")
    local info = onboard.probe(host, dir)
    local plan = onboard.plan(host, info)
    local err = onboard.preflight(host, info, plan)
    if conn.quiet and not plan.needs_nvim then
      -- Reconnecting in the background: never start optional downloads.
      plan.items = {}
    end
    if not err and #plan.items > 0 then
      if conn.quiet then
        error(util.err("install", ("'%s' needs first-time setup; run :RemoteSSH connect %s"):format(host, host)))
      end
      if unverified_net then
        progress(conn, "Checking the server's internet access")
        onboard.check_internet(host, info)
        unverified_net = false
      end
      if not conn.consented then
        if not onboard.consent(host, info, plan) then
          error(util.err("cancelled", "Setup cancelled; nothing was installed."))
        end
        conn.consented = true
      end
      local ok, ierr = pcall(onboard.install, host, plan, function(text)
        progress(conn, text)
      end)
      if not ok then
        if type(ierr) == "table" and ierr.kind == "dir" then
          err = ierr
        else
          error(ierr)
        end
      end
    end
    if not err then
      if #plan.items == 0 then
        return info, plan
      end
      -- Installed something: loop to re-probe and confirm the result.
      local after = onboard.probe(host, dir)
      local replan = onboard.plan(host, after)
      if replan.needs_nvim then
        error(util.err("install", ("Setup on '%s' finished but Neovim is still not usable there."):format(host)))
      end
      -- Optional components that could not be installed are not retried on
      -- every connect (:RemoteSSH setup retries them).
      local skip = {}
      skip.rg = after.rg == "none" or nil
      skip.mason = after.mason ~= "yes" or nil
      state.host(host).skip = skip
      state.save()
      replan = onboard.plan(host, after)
      return after, replan
    end
    if err.kind ~= "dir" or conn.quiet then
      error(err)
    end
    dir = onboard.ask_directory(host, err, info.base)
    if not dir then
      err.reported = true
      error(util.err("cancelled", "Setup cancelled."))
    end
  end
end

local function upload_agent(conn, base)
  local host = conn.host
  local target = base .. "/agent/agent.lua"
  local cmd = "exec sh -c " .. shq(("mkdir -p %s && cat > %s"):format(shq(base .. "/agent"), shq(target)))
  local res = await(function(cb)
    ssh.exec(host, cmd, { stdin = onboard.remote_file("agent.lua"), timeout = 60000 }, cb)
  end)
  if res.code ~= 0 then
    error(util.err("agent", ("Could not copy the agent to '%s'."):format(host), util.tail(res.stderr, 4)))
  end
  return target
end

local function start_agent(conn, nvim, agent_path, base)
  local host = conn.host
  local inner = ("echo %s; export NVIM_APPNAME=nvim-remote-ssh; exec %s -u NONE -i NONE -n -l %s %s 3>&1 1>&2"):format(
    AGENT_SENTINEL,
    shq(nvim),
    shq(agent_path),
    shq(base)
  )
  local args = ssh.base_args(host)
  vim.list_extend(args, { "--", host, "exec sh -c " .. shq(inner) })

  local session
  local stderr_tail = {}
  local ready_cb
  local handle, spawn_err = proc.spawn(ssh.cmd(), args, {
    env = ssh.env(),
    on_stdout = function(chunk)
      session:feed(chunk, AGENT_SENTINEL)
    end,
    on_stderr = function(chunk)
      stderr_tail[#stderr_tail + 1] = chunk
      if #stderr_tail > 20 then
        table.remove(stderr_tail, 1)
      end
      vim.schedule(function()
        log.debug(("[%s] agent: %s"):format(host, util.trim(chunk)))
      end)
    end,
    on_exit = function(code)
      vim.schedule(function()
        if ready_cb then
          ready_cb(false, code)
        end
        conn:_on_agent_exit(session, code)
      end)
    end,
  })
  if not handle then
    error(util.err("no_ssh", "Could not run ssh: " .. tostring(spawn_err)))
  end
  session = rpc.new(function(data)
    handle.write(data)
  end)

  local timer = uv.new_timer()
  local ok, code = await(function(cb)
    ready_cb = cb
    session:on("agent.ready", function()
      cb(true)
    end)
    timer:start(30000, 0, function()
      cb(false, "timeout")
    end)
  end)
  ready_cb = nil
  timer:stop()
  timer:close()
  if not ok then
    handle.kill()
    session:close()
    error(util.err(
      "agent",
      ("The remote agent on '%s' did not start (%s)."):format(host, tostring(code)),
      util.tail(table.concat(stderr_tail), 5)
    ))
  end
  conn.proc, conn.session = handle, session

  local err, pong = await(function(cb)
    session:request("ping", {}, cb)
  end)
  if err then
    handle.kill()
    error(util.err("agent", ("The remote agent on '%s' is not responding: %s"):format(host, err.message)))
  end
  return pong
end

local function establish(conn)
  if vim.fn.executable(ssh.cmd()) ~= 1 then
    error(ssh.classify(conn.host, "command not found", { spawn_failed = true }))
  end
  open_master(conn)
  local info, plan = prepare_server(conn)
  progress(conn, "Starting remote agent")
  local agent_path = upload_agent(conn, info.base)
  local pong = start_agent(conn, plan.nvim, agent_path, info.base)
  conn.info = info
  conn.agent = pong
  conn.home = pong.home or info.home
  conn:_wire_events()
end

-- ---------------------------------------------------------------------------
-- Public connection API
-- ---------------------------------------------------------------------------

--- Connect to `host` (idempotent). cb(err, conn).
--- opts.quiet: never prompt for retries/installs (used for auto-reconnect).
function M.connect(host, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  if not ssh.valid_host(host) then
    local err = util.err("host", ("Invalid host name: %q"):format(tostring(host)))
    log.error(err.message)
    return cb(err)
  end
  local conn = M.conns[host]
  if conn and conn.state == "connected" then
    return cb(nil, conn)
  end
  if not conn then
    conn = setmetatable({
      host = host,
      state = "disconnected",
      waiters = {},
      procs = {},
      next_proc = 0,
      listeners = {},
      forwards = {},
      attempts = 0,
    }, Conn)
    M.conns[host] = conn
  end
  table.insert(conn.waiters, cb)
  if conn.state == "connecting" then
    return
  end
  conn.state = "connecting"
  conn.user_closed = false
  conn.quiet = opts.quiet or false
  if conn.reconnect_timer then
    conn.reconnect_timer:stop()
    conn.reconnect_timer:close()
    conn.reconnect_timer = nil
  end

  util.async(function()
    establish(conn)
  end, function(err)
    conn.stage = nil
    progress(conn, nil)
    local waiters = conn.waiters
    conn.waiters = {}
    if err then
      conn.state = "disconnected"
      if conn.proc then
        conn.proc.kill()
      end
      if type(err) ~= "table" or not err.kind then
        err = util.err("internal", "remote-ssh internal error: " .. tostring(err))
      end
      conn.last_error = err
      if not conn.quiet and err.kind ~= "cancelled" and not err.reported then
        log.error(util.errmsg(err))
      elseif err.kind == "cancelled" and not conn.quiet then
        log.info(err.message)
      else
        log.debug(util.errmsg(err))
      end
      for _, w in ipairs(waiters) do
        w(err)
      end
      return
    end
    conn.state = "connected"
    conn.attempts = 0
    conn.last_error = nil
    log.debug(("[%s] connected (agent nvim %s)"):format(host, tostring(conn.agent.nvim)))
    fire("connected", conn)
    for _, w in ipairs(waiters) do
      w(nil, conn)
    end
  end)
end

--- Blocking connect, for places that must be synchronous (BufReadCmd).
function M.connect_sync(host, timeout)
  local done, rerr, rconn = false, nil, nil
  M.connect(host, {}, function(err, conn)
    done, rerr, rconn = true, err, conn
  end)
  vim.wait(timeout or 600000, function()
    return done
  end, 20)
  if not done then
    return nil, util.err("timeout", "Timed out connecting to " .. host)
  end
  return rconn, rerr
end

function Conn:_wire_events()
  local s = self.session
  local function forward(event)
    s:on(event, function(params)
      for _, fn in ipairs(self.listeners[event] or {}) do
        local ok, err = pcall(fn, params)
        if not ok then
          log.debug(event .. " listener failed: " .. tostring(err))
        end
      end
    end)
  end
  forward("fs.changed")
  forward("mason.progress")
  s:on("proc.stdout", function(p)
    local h = self.procs[p.id]
    if h and h.on_stdout then
      h.on_stdout(p.data)
    end
  end)
  s:on("proc.stderr", function(p)
    local h = self.procs[p.id]
    if h and h.on_stderr then
      h.on_stderr(p.data)
    end
  end)
  s:on("proc.exit", function(p)
    local h = self.procs[p.id]
    self.procs[p.id] = nil
    if h and h.on_exit then
      h.on_exit(p.code, p.signal)
    end
  end)
end

--- Listen for agent events ("fs.changed", "mason.progress"); survives
--- reconnects.
function Conn:on(event, fn)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], fn)
end

function Conn:_on_agent_exit(session, code)
  if session then
    session:close()
  end
  if self.session ~= session then
    return -- an older agent, or one that never became current
  end
  self.session, self.proc = nil, nil
  local procs = self.procs
  self.procs = {}
  for _, h in pairs(procs) do
    if h.on_exit then
      pcall(h.on_exit, -1, 0)
    end
  end
  if self.state ~= "connected" then
    return
  end
  self.state = "disconnected"
  fire("disconnected", self)
  if self.user_closed then
    return
  end
  log.warn(("Connection to '%s' was lost (agent exited with %s). Unsaved changes are kept."):format(self.host, tostring(code)))
  self:_schedule_reconnect()
end

function Conn:_schedule_reconnect()
  local cfg = config.get().reconnect
  if not cfg.auto or self.user_closed then
    return
  end
  self.attempts = self.attempts + 1
  local delay = cfg.delays[self.attempts]
  if not delay then
    log.warn(("Could not reconnect to '%s'. Use :RemoteSSH reconnect to try again."):format(self.host))
    return
  end
  local timer = uv.new_timer()
  self.reconnect_timer = timer
  timer:start(delay * 1000, 0, function()
    timer:stop()
    timer:close()
    vim.schedule(function()
      if self.reconnect_timer ~= timer then
        return
      end
      self.reconnect_timer = nil
      if self.user_closed or self.state ~= "disconnected" then
        return
      end
      local attempts = self.attempts
      M.connect(self.host, { quiet = true }, function(err)
        if err then
          self.attempts = attempts
          self:_schedule_reconnect()
        else
          log.info(("Reconnected to '%s'."):format(self.host))
        end
      end)
    end)
  end)
end

local NOT_CONNECTED = { code = "ECLOSED", message = "not connected to the server" }

--- Asynchronous agent request: cb(err, result).
function Conn:request(method, params, cb)
  if not self.session then
    if cb then
      vim.schedule(function()
        cb(NOT_CONNECTED)
      end)
    end
    return
  end
  return self.session:request(method, params, cb)
end

--- Blocking agent request: returns result or nil, err.
function Conn:call(method, params, timeout)
  if not self.session then
    return nil, NOT_CONNECTED
  end
  return self.session:call(method, params, timeout or config.get().timeout)
end

--- Request from inside a util.async coroutine: returns err, result.
function Conn:arequest(method, params)
  return await(function(cb)
    self:request(method, params, cb)
  end)
end

function Conn:notify(method, params)
  if self.session then
    self.session:notify(method, params)
  end
end

--- Start a process on the server with streaming output.
--- opts: cwd, env, on_stdout(data), on_stderr(data), on_exit(code, signal).
--- cb(err, handle) with handle { id, write(data), close_stdin(), kill(sig) }.
function Conn:spawn(cmd, opts, cb)
  opts = opts or {}
  self.next_proc = self.next_proc + 1
  local id = self.next_proc
  local h = { id = id, on_stdout = opts.on_stdout, on_stderr = opts.on_stderr, on_exit = opts.on_exit }
  local conn = self
  function h.write(data)
    conn:notify("proc.write", { id = id, data = data })
  end
  function h.close_stdin()
    conn:notify("proc.close_stdin", { id = id })
  end
  function h.kill(signal)
    conn:notify("proc.kill", { id = id, signal = signal })
  end
  self.procs[id] = h
  self:request("proc.spawn", { id = id, cmd = cmd, cwd = opts.cwd, env = opts.env }, function(err, res)
    if err then
      self.procs[id] = nil
      return cb(err)
    end
    h.pid = res.pid
    cb(nil, h)
  end)
  return h
end

--- Close the connection on purpose (no auto-reconnect).
function Conn:close(cb)
  self.user_closed = true
  if self.reconnect_timer then
    self.reconnect_timer:stop()
    self.reconnect_timer:close()
    self.reconnect_timer = nil
  end
  if self.session then
    self.session:notify("shutdown", {})
  end
  local p = self.proc
  if p then
    vim.defer_fn(function()
      p.kill()
    end, 500)
  end
  ssh.control(self.host, "exit", nil, function()
    if cb then
      cb()
    end
  end)
end

--- Close everything; used on VimLeavePre.
function M.close_all()
  local pending = 0
  for _, conn in pairs(M.conns) do
    if conn.state == "connected" or conn.state == "connecting" then
      pending = pending + 1
      conn:close(function()
        pending = pending - 1
      end)
    end
  end
  vim.wait(2000, function()
    return pending == 0
  end, 20)
end

return M
