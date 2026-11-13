-- Host aliases from the user's ssh configuration (for the host picker).
local M = {}

local function expand(path, base)
  if path:sub(1, 1) == "~" then
    path = (os.getenv("HOME") or "") .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    path = base .. "/" .. path
  end
  return path
end

local function parse(file, hosts, seen, depth)
  if depth > 8 or seen[file] then
    return
  end
  seen[file] = true
  local f = io.open(file, "r")
  if not f then
    return
  end
  local ssh_dir = (os.getenv("HOME") or "") .. "/.ssh"
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local key, value = line:match("^(%S-)%s*[=%s]%s*(.+)$")
      if key then
        key = key:lower()
        if key == "host" then
          for name in value:gmatch("%S+") do
            name = name:gsub('^"(.*)"$', "%1")
            -- Patterns and negations are rules, not hosts.
            if not name:find("[*?!]") and not hosts.set[name] then
              hosts.set[name] = true
              hosts.list[#hosts.list + 1] = name
            end
          end
        elseif key == "include" then
          for pattern in value:gmatch("%S+") do
            for _, inc in ipairs(vim.fn.glob(expand(pattern, ssh_dir), false, true)) do
              parse(inc, hosts, seen, depth + 1)
            end
          end
        end
      end
    end
  end
  f:close()
end

--- List of host aliases, in file order.
function M.hosts()
  local cfg = require("remote-ssh.config").get().ssh
  local hosts = { list = {}, set = {} }
  local seen = {}
  if cfg.config_file then
    parse(vim.fn.expand(cfg.config_file), hosts, seen, 0)
  else
    parse((os.getenv("HOME") or "") .. "/.ssh/config", hosts, seen, 0)
    parse("/etc/ssh/ssh_config", hosts, seen, 0)
  end
  return hosts.list
end

return M
