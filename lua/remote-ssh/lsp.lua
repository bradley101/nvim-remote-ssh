-- Language servers run ON THE SERVER (so they see the real project, its
-- toolchain and dependencies); Neovim's built-in LSP client talks to them
-- through the agent. Document URIs are translated in both directions:
--   client side  rssh://<host>/abs/path   <->   server side  file:///abs/path
local api = vim.api
local P = require("remote-ssh.path")
local connection = require("remote-ssh.connection")
local config = require("remote-ssh.config")
local ui = require("remote-ssh.ui")
local log = require("remote-ssh.log")
local util = require("remote-ssh.util")

local M = {}

-- ---------------------------------------------------------------------------
-- URI translation
-- ---------------------------------------------------------------------------

local function map_strings(value, fn)
  local t = type(value)
  if t == "string" then
    return fn(value)
  elseif t ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[type(k) == "string" and fn(k) or k] = map_strings(v, fn)
  end
  return setmetatable(out, getmetatable(value)) -- keeps vim.empty_dict() markers
end

--- Returns to_server(value), to_client(value) for a host.
function M.translators(host)
  local prefix = P.scheme .. host .. "/"
  local plen = #prefix
  local function out(s)
    if s:sub(1, plen) == prefix then
      return vim.uri_from_fname(s:sub(plen))
    end
    return s
  end
  local function inn(s)
    if s:sub(1, 8) == "file:///" then
      local ok, fname = pcall(vim.uri_to_fname, s)
      if ok then
        return P.scheme .. host .. fname
      end
    end
    return s
  end
  return function(v)
    return map_strings(v, out)
  end, function(v)
    return map_strings(v, inn)
  end
end

-- ---------------------------------------------------------------------------
-- JSON-RPC client over a remote process (the object vim.lsp expects from a
-- `cmd` function)
-- ---------------------------------------------------------------------------

local function json_decode(body)
  local ok, res = pcall(vim.json.decode, body, { luanil = { object = true } })
  if not ok then
    ok, res = pcall(vim.json.decode, body)
  end
  return ok and res or nil
end

--- Build a `cmd` function for vim.lsp.start that runs `cmd` on conn's host.
function M.remote_cmd(conn, cmd, opts)
  opts = opts or {}
  return function(dispatchers)
    local to_server, to_client = M.translators(conn.host)
    local next_id, pending, closing = 0, {}, false
    local buf = ""
    local stderr_seen = false
    local handle

    local function send(msg)
      if closing then
        return false
      end
      local body = vim.json.encode(msg)
      handle.write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
      return true
    end

    local function safe(fn, ...)
      local ok, a, b = pcall(fn, ...)
      if not ok then
        log.debug("lsp dispatcher error: " .. tostring(a))
        return nil, nil, a
      end
      return a, b
    end

    local function on_message(msg)
      if type(msg) ~= "table" then
        return
      end
      msg = to_client(msg)
      local id = msg.id
      if id == vim.NIL then
        id = nil
      end
      if msg.method and id ~= nil then
        local result, err, crash = safe(dispatchers.server_request, msg.method, msg.params)
        if crash then
          err = { code = -32603, message = tostring(crash) }
        end
        if err then
          send({ jsonrpc = "2.0", id = id, error = err })
        else
          send({ jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or to_server(result) })
        end
      elseif msg.method then
        safe(dispatchers.notification, msg.method, msg.params)
      elseif id ~= nil then
        local p = pending[id]
        pending[id] = nil
        if p then
          if p.notify_reply then
            safe(p.notify_reply, id)
          end
          local err, result = msg.error, msg.result
          if err == vim.NIL then
            err = nil
          end
          if result == vim.NIL then
            result = nil
          end
          safe(p.callback, err, result)
        end
      end
    end

    local function feed(data)
      buf = buf .. data
      while true do
        local hstart, hend = buf:find("\r\n\r\n", 1, true)
        if not hstart then
          return
        end
        local len = tonumber(buf:sub(1, hstart):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
        if not len then
          buf = buf:sub(hend + 1) -- garbage header; resynchronise
        else
          if #buf < hend + len then
            return
          end
          local body = buf:sub(hend + 1, hend + len)
          buf = buf:sub(hend + len + 1)
          on_message(json_decode(body))
        end
      end
    end

    handle = conn:spawn(cmd, {
      cwd = opts.cwd,
      env = opts.env,
      on_stdout = feed,
      on_stderr = function(data)
        if not stderr_seen then
          stderr_seen = true
        end
        log.debug(("[%s] %s: %s"):format(conn.host, opts.name or cmd[1], util.trim(data)))
      end,
      on_exit = function(code, signal)
        closing = true
        safe(dispatchers.on_exit, code or -1, signal or 0)
      end,
    }, function(err)
      if err then
        closing = true
        log.error(("Could not start language server %s on '%s': %s"):format(opts.name or cmd[1], conn.host, err.message or err.code))
        safe(dispatchers.on_exit, -1, 0)
      end
    end)

    local client = {}

    function client.request(method, params, callback, notify_reply_callback)
      if closing then
        return false
      end
      next_id = next_id + 1
      local id = next_id
      params = to_server(params)
      if method == "initialize" and type(params) == "table" then
        -- Our pid means nothing on the server; servers that watch their
        -- parent would exit immediately.
        params.processId = vim.NIL
      end
      pending[id] = { callback = callback, notify_reply = notify_reply_callback }
      send({ jsonrpc = "2.0", id = id, method = method, params = params })
      return true, id
    end

    function client.notify(method, params)
      return send({ jsonrpc = "2.0", method = method, params = to_server(params) })
    end

    function client.is_closing()
      return closing
    end

    function client.terminate()
      if not closing then
        closing = true
        handle.kill()
      end
    end

    return client
  end
end

-- ---------------------------------------------------------------------------
-- Choosing and starting servers
-- ---------------------------------------------------------------------------

--- Names of the servers to consider for remote buffers.
function M.server_names()
  local cfg = config.get().lsp
  if cfg.servers then
    return cfg.servers
  end
  local names, seen = {}, {}
  local function add(n)
    if type(n) == "string" and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  -- Everything the user enabled with vim.lsp.enable().
  if type(vim.lsp._enabled_configs) == "table" then
    for name in pairs(vim.lsp._enabled_configs) do
      add(name)
    end
  end
  for name in pairs(cfg.configs or {}) do
    add(name)
  end
  table.sort(names)
  return names
end

--- Resolved configuration for a server: vim.lsp.config[name] overlaid with
--- remote-ssh's own lsp.configs[name].
function M.get_config(name)
  local base
  if vim.lsp.config then
    local ok, c = pcall(function()
      return vim.lsp.config[name]
    end)
    if ok and type(c) == "table" then
      base = vim.deepcopy(c)
    end
  end
  local over = (config.get().lsp.configs or {})[name]
  if not base and not over then
    return nil
  end
  return vim.tbl_deep_extend("force", base or {}, over or {})
end

local function marker_groups(markers)
  local groups = {}
  for _, m in ipairs(markers or {}) do
    if type(m) == "table" then
      groups[#groups + 1] = m
    else
      groups[#groups + 1] = { m }
    end
  end
  return groups
end

local warned = {}
local function warn_once(key, msg)
  if not warned[key] then
    warned[key] = true
    log.warn(msg)
  end
end

local declined = {} -- host/server -> true: user said "not now"
local installing = {} -- host/package -> list of callbacks

--- Make sure cmd[1] exists on the server, offering to install it.
--- Runs in a coroutine; returns true when the server can be started.
local function ensure_executable(conn, name, exe)
  local err, found = conn:arequest("which", { names = { exe } })
  if err then
    return false
  end
  if found[exe] and found[exe] ~= vim.NIL then
    return true
  end
  local key = conn.host .. "/" .. name
  if declined[key] then
    return false
  end
  local cfg = config.get().lsp
  if not cfg.auto_install or not (conn.agent and conn.agent.mason) then
    warn_once(key, ("Language server '%s' is not installed on '%s' (%s not found)."):format(name, conn.host, exe))
    declined[key] = true
    return false
  end

  local rerr, res = conn:arequest("mason.resolve", { server = name })
  if rerr then
    warn_once(key, ("Could not look up '%s' in the mason registry on '%s': %s"):format(name, conn.host, rerr.message or rerr.code))
    declined[key] = true
    return false
  end
  local pkg = res.package ~= vim.NIL and res.package or nil
  if not pkg then
    warn_once(key, ("Language server '%s' (%s) is not installed on '%s', and mason has no package for it. Install it on the server manually."):format(name, exe, conn.host))
    declined[key] = true
    return false
  end

  local ikey = conn.host .. "/" .. pkg
  if not installing[ikey] then
    if declined[key] then
      return false
    end
    local choice = ui.confirm(("Language server '%s' is not installed on '%s'.\nInstall the mason package '%s' there now?"):format(name, conn.host, pkg), { "Install", "Not now" })
    if choice ~= 1 then
      declined[key] = true
      return false
    end
    installing[ikey] = {}
    log.info(("Installing %s on '%s'..."):format(pkg, conn.host))
    conn:request("mason.install", { package = pkg }, function(ierr)
      local waiters = installing[ikey]
      installing[ikey] = nil
      if ierr then
        declined[key] = true
        log.error(("Installing %s on '%s' failed:\n%s"):format(pkg, conn.host, util.tail(ierr.message or ierr.code, 8)))
      else
        log.info(("Installed %s on '%s'."):format(pkg, conn.host))
      end
      for _, w in ipairs(waiters) do
        w(ierr)
      end
    end)
  end
  local ierr = util.await(function(cb)
    table.insert(installing[ikey], cb)
  end)
  if ierr then
    return false
  end
  err, found = conn:arequest("which", { names = { exe } })
  if err or not found[exe] or found[exe] == vim.NIL then
    warn_once(key .. "/path", ("%s was installed on '%s' but '%s' is still not on its PATH."):format(pkg, conn.host, exe))
    declined[key] = true
    return false
  end
  return true
end

local function start(conn, name, cfg, bufnr)
  local meta = require("remote-ssh.buffer").meta[bufnr]
  if not meta then
    return
  end
  local cmd = cfg.cmd
  if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
    return warn_once("cmd/" .. name, ("Language server '%s' has no command list, so it cannot be started on a remote host. Set lsp.configs.%s.cmd in remote-ssh's setup."):format(name, name))
  end
  util.async(function()
    if not ensure_executable(conn, name, cmd[1]) then
      return
    end
    local workspace = require("remote-ssh").workspace_for(conn.host, meta.path)
    local root
    local groups = marker_groups(cfg.root_markers)
    if #groups > 0 then
      local err, res = conn:arequest("fs.find_root", { path = meta.path, groups = groups })
      if not err and res.root ~= vim.NIL then
        root = res.root
      end
    end
    root = root or workspace or P.dirname(meta.path)
    if not api.nvim_buf_is_valid(bufnr) or conn.state ~= "connected" then
      return
    end

    local final = vim.deepcopy(cfg)
    final.name = name
    final.cmd = M.remote_cmd(conn, cmd, { cwd = root, env = cfg.cmd_env, name = name })
    final.cmd_cwd, final.cmd_env = nil, nil
    final.root_dir = root
    final.workspace_folders = nil
    final.rssh_host = conn.host
    final.capabilities = final.capabilities or vim.lsp.protocol.make_client_capabilities()
    -- File watching is the server's own job; our watcher only sees local files.
    final.capabilities.workspace = final.capabilities.workspace or {}
    final.capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false }

    api.nvim_buf_call(bufnr, function()
      vim.lsp.start(final, {
        bufnr = bufnr,
        reuse_client = function(client, conf)
          return client.name == conf.name and client.config.rssh_host == conf.rssh_host and client.config.root_dir == conf.root_dir
        end,
      })
    end)
  end, function(err)
    if err then
      log.error(("Starting language server '%s' failed: %s"):format(name, util.errmsg(err)))
    end
  end)
end

--- Start/attach every applicable server for a remote buffer.
function M.attach(bufnr)
  if not config.get().lsp.enabled then
    return
  end
  local meta = require("remote-ssh.buffer").meta[bufnr]
  if not meta or meta.failed then
    return
  end
  local conn = connection.get(meta.host)
  if not conn or conn.state ~= "connected" then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    return
  end
  for _, name in ipairs(M.server_names()) do
    local cfg = M.get_config(name)
    if cfg and (cfg.filetypes == nil or vim.tbl_contains(cfg.filetypes, ft)) then
      start(conn, name, cfg, bufnr)
    end
  end
end

function M.setup()
  local group = api.nvim_create_augroup("RemoteSSHLsp", { clear = true })
  api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      if require("remote-ssh.buffer").meta[args.buf] then
        M.attach(args.buf)
      end
    end,
  })
  -- After a reconnect the old servers are gone: start them again.
  connection.on("connected", function(conn)
    vim.schedule(function()
      for bufnr, meta in pairs(require("remote-ssh.buffer").meta) do
        if meta.host == conn.host and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
          M.attach(bufnr)
        end
      end
    end)
  end)
end

M._declined = declined
return M
