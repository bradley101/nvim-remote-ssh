-- Local port forwarding on the shared connection.
local ssh = require("remote-ssh.ssh")
local log = require("remote-ssh.log")
local connection = require("remote-ssh.connection")

local M = {}

--- "8080" | "8080:3000" | "8080:otherhost:3000"  ->  normalized spec
function M.parse(spec)
  local a, b, c = spec:match("^(%d+):([^:]+):(%d+)$")
  if a then
    return ("%s:%s:%s"):format(a, b, c), tonumber(a)
  end
  a, c = spec:match("^(%d+):(%d+)$")
  if a then
    return ("%s:localhost:%s"):format(a, c), tonumber(a)
  end
  a = spec:match("^(%d+)$")
  if a then
    return ("%s:localhost:%s"):format(a, a), tonumber(a)
  end
  return nil
end

function M.add(conn, spec, cb)
  local norm, lport = M.parse(spec)
  if not norm or lport < 1 or lport > 65535 then
    log.error(("Invalid port forward %q. Use LOCAL, LOCAL:REMOTE or LOCAL:HOST:REMOTE."):format(spec))
    return cb and cb(false)
  end
  ssh.control(conn.host, "forward", { "-L", "127.0.0.1:" .. norm }, function(res)
    if res.code ~= 0 then
      local why = res.stderr:find("in use", 1, true) and ("local port %d is already in use"):format(lport)
        or res.stderr:find("ermission denied", 1, true) and ("no permission to listen on port %d"):format(lport)
        or require("remote-ssh.util").tail(res.stderr, 2)
      log.error(("Could not forward %s: %s"):format(norm, why))
      return cb and cb(false)
    end
    conn.forwards[norm] = true
    log.info(("Forwarding localhost:%d -> %s:%s (via %s)"):format(lport, norm:match(":(.-):"), norm:match(":(%d+)$"), conn.host))
    return cb and cb(true)
  end)
end

function M.remove(conn, spec, cb)
  local norm = M.parse(spec)
  if not norm or not conn.forwards[norm] then
    log.warn("No such forward: " .. spec)
    return cb and cb(false)
  end
  ssh.control(conn.host, "cancel", { "-L", "127.0.0.1:" .. norm }, function(res)
    conn.forwards[norm] = nil
    if res.code ~= 0 then
      log.debug("cancel forward: " .. res.stderr)
    end
    return cb and cb(true)
  end)
end

function M.list(conn)
  local out = {}
  for spec in pairs(conn.forwards) do
    out[#out + 1] = spec
  end
  table.sort(out)
  return out
end

function M.setup()
  -- A new shared connection starts without forwards: restore them.
  connection.on("connected", function(conn)
    for spec in pairs(conn.forwards) do
      ssh.control(conn.host, "forward", { "-L", "127.0.0.1:" .. spec }, function(res)
        if res.code ~= 0 and not res.stderr:find("in use", 1, true) then
          conn.forwards[spec] = nil
          log.warn(("Port forward %s could not be restored."):format(spec))
        end
      end)
    end
  end)
end

return M
