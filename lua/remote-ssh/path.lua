-- Remote files are addressed as  rssh://<host>/<absolute path>
local M = {}

M.scheme = "rssh://"

--- Collapse //, . and .. ; always absolute; no trailing slash (except "/").
function M.normalize(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- Split a buffer name into host and normalized path (nil if not ours).
function M.parse(name)
  local host, path = (name or ""):match("^rssh://([^/]+)(/.*)$")
  if not host then
    host = (name or ""):match("^rssh://([^/]+)$")
    path = host and "/" or nil
  end
  if not host then
    return nil
  end
  return host, M.normalize(path)
end

function M.uri(host, path)
  return M.scheme .. host .. M.normalize(path)
end

function M.is_remote(name)
  return (name or ""):sub(1, #M.scheme) == M.scheme
end

function M.join(dir, name)
  return M.normalize(dir .. "/" .. name)
end

function M.dirname(path)
  local d = path:match("^(.*)/[^/]*$")
  return (d == nil or d == "") and "/" or d
end

function M.basename(path)
  return path:match("([^/]*)$")
end

--- Path relative to root when inside it, else the absolute path.
function M.relative(path, root)
  if root and root ~= "/" and path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  if root == "/" then
    return path:sub(2)
  end
  return path
end

return M
