-- The list of files in a remote workspace, fetched once and then kept up to
-- date, so finding files (<leader>ff, :RemoteSSH files) needs no round trip.
--
-- The agent lists the workspace when it is opened and watches its folders;
-- it sends "index.changed" notifications with the files added and removed,
-- which are applied here. Changes made from Neovim (explorer, saving a new
-- file) are applied right away as well. When the server cannot watch (too
-- many files, or the system's watch limit is reached) the cached list is
-- still used, and listed again in the background when it is older than
-- REFRESH_AFTER.
local config = require("remote-ssh.config")
local log = require("remote-ssh.log")

local M = {}

local REFRESH_AFTER = 30 -- seconds, only when the server cannot watch

--- host -> root -> cache entry
M.caches = {}
local by_id = {}
local seq = 0
local hooked = false

local function now()
  return (vim.uv or vim.loop).now() / 1000
end

local function set_files(c, files)
  c.files, c.pos = files, {}
  for i, f in ipairs(files) do
    c.pos[f] = i
  end
end

local function add(c, rel)
  if rel ~= "" and not c.pos[rel] then
    local n = #c.files + 1
    c.files[n] = rel
    c.pos[rel] = n
  end
end

local function remove(c, rel)
  local i = c.pos[rel]
  if not i then
    return
  end
  local n = #c.files
  local last = c.files[n]
  c.files[i] = last
  c.pos[last] = i
  c.files[n] = nil
  c.pos[rel] = nil
end

--- Remove `rel` and everything under it.
local function remove_tree(c, rel)
  remove(c, rel)
  local prefix = rel == "" and "" or rel .. "/"
  local gone = {}
  for _, f in ipairs(c.files) do
    if f:sub(1, #prefix) == prefix then
      gone[#gone + 1] = f
    end
  end
  for _, f in ipairs(gone) do
    remove(c, f)
  end
  return #gone
end

--- Path relative to root, or nil when path is not inside it.
local function rel_to(root, path)
  if root == "/" then
    return path:sub(2)
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return nil
end

local function finish(c, err)
  local waiters = c.waiters
  c.waiters = {}
  for _, cb in ipairs(waiters) do
    if err then
      cb(err)
    else
      cb(nil, c.files, c.truncated)
    end
  end
end

local function on_changed(params)
  local c = by_id[params.id]
  if not c then
    return
  end
  if params.overflow then
    c.watching = false
    log.debug(("[%s] no longer watching %s: %s"):format(c.host, c.root, tostring(params.reason)))
    return
  end
  if c.state ~= "ready" then
    return
  end
  for _, rel in ipairs(params.removed or {}) do
    remove(c, rel)
  end
  for _, rel in ipairs(params.added or {}) do
    add(c, rel)
  end
end

local function hook(conn)
  if not hooked then
    hooked = true
    local connection = require("remote-ssh.connection")
    connection.on("disconnected", function(c)
      M.drop(c.host)
    end)
    connection.on("connected", function(c)
      -- The agent was restarted, so its index and watches are gone.
      M.drop(c.host)
      local root = require("remote-ssh").workspaces[c.host]
      if root and config.get().search.file_cache then
        M.warm(c, root)
      end
    end)
  end
  if not conn.filecache_hooked then
    conn.filecache_hooked = true
    conn:on("index.changed", on_changed)
  end
end

--- Whether the server has ripgrep, without blocking. cb(bool).
local function has_rg(conn, cb)
  conn.tools = conn.tools or {}
  if conn.tools.rg ~= nil then
    return cb(conn.tools.rg and true or false)
  end
  conn:request("which", { names = { "rg" } }, function(err, res)
    if not err and conn.tools.rg == nil then
      conn.tools.rg = (res and res.rg and res.rg ~= vim.NIL) and res.rg or false
    end
    cb(conn.tools.rg and true or false)
  end)
end

local start

--- Ask the agent for the file list (again). The current list, if any, stays
--- in use until the new one arrives.
local function fetch(conn, c)
  if c.fetching then
    return
  end
  c.fetching = true
  seq = seq + 1
  local old_id = c.id
  local id = ("%s:%d"):format(c.root, seq)
  c.id = id
  by_id[id] = c
  has_rg(conn, function(rg)
    if c.id == id then
      start(conn, c, id, old_id, rg)
    end
  end)
end

start = function(conn, c, id, old_id, rg)
  local started = now()
  conn:request("index.start", {
    id = id,
    root = c.root,
    rg = rg,
    max = config.get().search.max_files,
  }, function(err, res)
    if c.id ~= id then
      return -- dropped or replaced meanwhile
    end
    c.fetching = false
    if old_id then
      by_id[old_id] = nil
      conn:notify("index.stop", { id = old_id })
    end
    if err then
      by_id[id] = nil
      c.id = old_id
      if c.state ~= "ready" then
        M.caches[c.host][c.root] = nil
        return finish(c, err)
      end
      return log.debug(("[%s] listing %s again failed: %s"):format(c.host, c.root, err.message or err.code))
    end
    set_files(c, res.files or {})
    c.truncated = res.truncated == true
    c.watching = res.watching == true
    c.fetched_at = now()
    c.state = "ready"
    log.debug(("[%s] indexed %d files in %s (%.1fs, %s)"):format(
      c.host,
      #c.files,
      c.root,
      c.fetched_at - started,
      c.watching and "watching" or "not watching"
    ))
    finish(c)
  end)
end

--- Start building the file list of `root` in the background (idempotent).
--- Returns the cache entry.
function M.warm(conn, root)
  hook(conn)
  local host = conn.host
  M.caches[host] = M.caches[host] or {}
  local c = M.caches[host][root]
  if not c then
    c = { host = host, root = root, state = "loading", files = {}, pos = {}, waiters = {} }
    M.caches[host][root] = c
    fetch(conn, c)
  end
  return c
end

--- Is the file list of root ready to use without waiting?
function M.ready(host, root)
  local c = M.caches[host] and M.caches[host][root]
  return c ~= nil and c.state == "ready"
end

--- The files under root (relative paths). cb(err, files, truncated); called
--- right away when the list is cached. Do not modify `files`.
function M.get(conn, root, cb)
  if not config.get().search.file_cache then
    return require("remote-ssh.search").files(conn, root, cb)
  end
  local c = M.warm(conn, root)
  if c.state ~= "ready" then
    table.insert(c.waiters, cb)
    return
  end
  if not c.watching and now() - (c.fetched_at or 0) > REFRESH_AFTER then
    fetch(conn, c) -- in the background; this call uses the current list
  end
  cb(nil, c.files, c.truncated)
end

--- Forget the cached lists of host (all hosts when nil).
function M.drop(host)
  for h, roots in pairs(M.caches) do
    if host == nil or h == host then
      for _, c in pairs(roots) do
        if c.id then
          by_id[c.id] = nil
          local conn = require("remote-ssh.connection").get(h)
          if conn and conn.state == "connected" then
            conn:notify("index.stop", { id = c.id })
          end
        end
        c.id = nil
        if c.state ~= "ready" then
          finish(c, { code = "ECANCELED", message = "the file list was reset" })
        end
      end
      M.caches[h] = nil
    end
  end
end

--- List the workspace of host again from scratch.
function M.reset(host)
  M.drop(host)
  local conn = require("remote-ssh.connection").get(host)
  local root = require("remote-ssh").workspaces[host]
  if conn and conn.state == "connected" and root then
    M.warm(conn, root)
  end
end

local function each(host, path, fn)
  for root, c in pairs(M.caches[host] or {}) do
    if c.state == "ready" then
      local rel = rel_to(root, path)
      if rel and rel ~= "" then
        fn(c, rel, root)
      end
    end
  end
end

--- A file was created (or written) at path on host.
function M.added(host, path)
  each(host, path, add)
end

--- path (a file or a folder with everything in it) was deleted on host.
function M.removed(host, path)
  each(host, path, remove_tree)
end

--- A file or folder was renamed on host.
function M.renamed(host, from, to)
  for root, c in pairs(M.caches[host] or {}) do
    if c.state == "ready" then
      local rf, rt = rel_to(root, from), rel_to(root, to)
      local moved = {}
      if rf and rf ~= "" then
        if c.pos[rf] then
          moved[#moved + 1] = ""
        end
        local prefix = rf .. "/"
        for _, f in ipairs(c.files) do
          if f:sub(1, #prefix) == prefix then
            moved[#moved + 1] = f:sub(#rf + 1)
          end
        end
        for _, suffix in ipairs(moved) do
          remove(c, rf .. suffix)
        end
      end
      if rt and rt ~= "" then
        for _, suffix in ipairs(moved) do
          add(c, rt .. suffix)
        end
      end
    end
  end
end

--- Something under path changed in a way only a new listing can tell
--- (a folder was copied). Without a watcher, list again on next use.
function M.changed(host, path)
  each(host, path, function(c)
    if not c.watching then
      c.fetched_at = 0
    end
  end)
end

return M
