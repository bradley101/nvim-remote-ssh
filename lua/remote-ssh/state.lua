-- Small persistent store (per-host install directory, recent workspaces).
local M = {}

local function file()
  return vim.fn.stdpath("data") .. "/remote-ssh/state.json"
end

local cache

function M.load()
  if cache then
    return cache
  end
  cache = { hosts = {}, recent = {}, cursors = {} }
  local f = io.open(file(), "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      cache.hosts = type(data.hosts) == "table" and data.hosts or {}
      cache.recent = type(data.recent) == "table" and data.recent or {}
      cache.cursors = type(data.cursors) == "table" and data.cursors or {}
    end
  end
  return cache
end

function M.save()
  if not cache then
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(file(), ":h"), "p")
  local f = io.open(file(), "w")
  if f then
    f:write(vim.json.encode(cache))
    f:close()
  end
end

function M.host(host)
  local s = M.load()
  if type(s.hosts[host]) ~= "table" then
    s.hosts[host] = {}
  end
  return s.hosts[host]
end

--- Remember a workspace as most recently used.
function M.add_recent(host, path)
  local s = M.load()
  local list = { { host = host, path = path } }
  for _, r in ipairs(s.recent) do
    if not (r.host == host and r.path == path) and #list < 30 then
      list[#list + 1] = r
    end
  end
  s.recent = list
  M.save()
end

--- Remember where the cursor was in a remote file (kept in memory until
--- M.save()).
function M.set_cursor(uri, pos)
  local s = M.load()
  if vim.tbl_isempty(s.cursors) then
    s.cursors = vim.empty_dict()
  end
  if s.cursors[uri] == nil and vim.tbl_count(s.cursors) >= 500 then
    s.cursors = vim.empty_dict() -- crude cap; positions are a convenience
  end
  s.cursors[uri] = { pos[1], pos[2] }
end

function M.get_cursor(uri)
  local pos = M.load().cursors[uri]
  if type(pos) == "table" and type(pos[1]) == "number" then
    return { pos[1], pos[2] or 0 }
  end
  return nil
end

function M.recent()
  return M.load().recent
end

return M
