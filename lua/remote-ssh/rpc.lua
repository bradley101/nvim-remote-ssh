-- Client end of the agent protocol (see remote/agent.lua for the framing).
local M = {}
M.__index = M

--- write(bytes): sends raw bytes to the agent.
function M.new(write)
  return setmetatable({
    write = write,
    next_id = 0,
    pending = {},
    listeners = {},
    chunks = {},
    size = 0,
    need = nil,
    synced = false,
    closed = false,
  }, M)
end

local function frame(msg)
  local payload = vim.mpack.encode(msg)
  local n = #payload
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    .. payload
end

--- Feed raw bytes received from the agent (fast context safe).
--- Everything before `sentinel` (a full line) is discarded: it is whatever
--- the remote shell's startup files printed.
function M:feed(data, sentinel)
  if not self.synced then
    self.pre = (self.pre or "") .. data
    local s, e = self.pre:find(sentinel .. "\n", 1, true)
    if not s then
      return
    end
    data = self.pre:sub(e + 1)
    self.pre = nil
    self.synced = true
  end
  self.chunks[#self.chunks + 1] = data
  self.size = self.size + #data
  while true do
    if not self.need then
      if self.size < 4 then
        break
      end
      local s = table.concat(self.chunks)
      self.chunks = { s }
      local a, b, c, d = s:byte(1, 4)
      self.need = ((a * 256 + b) * 256 + c) * 256 + d
    end
    if self.size < 4 + self.need then
      break
    end
    local s = table.concat(self.chunks)
    local payload = s:sub(5, 4 + self.need)
    local rest = s:sub(5 + self.need)
    self.chunks, self.size, self.need = { rest }, #rest, nil
    local ok, msg = pcall(vim.mpack.decode, payload)
    if ok and type(msg) == "table" then
      vim.schedule(function()
        self:_dispatch(msg)
      end)
    end
  end
end

local function denil(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

function M:_dispatch(msg)
  if msg[1] == 1 then
    local cb = self.pending[msg[2]]
    self.pending[msg[2]] = nil
    if cb then
      cb(denil(msg[3]), denil(msg[4]))
    end
  elseif msg[1] == 2 then
    for _, fn in ipairs(self.listeners[msg[2]] or {}) do
      local ok, err = pcall(fn, msg[3] or {})
      if not ok then
        require("remote-ssh.log").debug("event handler failed: " .. tostring(err))
      end
    end
  end
  -- Requests from the agent are deliberately not supported: the server can
  -- never make the client do anything.
end

local CLOSED = { code = "ECLOSED", message = "not connected to the server" }

--- Asynchronous request. cb(err, result); err is {code, message}.
function M:request(method, params, cb)
  if self.closed then
    if cb then
      vim.schedule(function()
        cb(CLOSED)
      end)
    end
    return
  end
  self.next_id = self.next_id + 1
  self.pending[self.next_id] = cb or function() end
  self.write(frame({ 0, self.next_id, method, params or {} }))
  return self.next_id
end

function M:notify(method, params)
  if not self.closed then
    self.write(frame({ 2, method, params or {} }))
  end
end

--- Blocking request (keeps processing events while waiting).
--- Returns result, or nil + err.
function M:call(method, params, timeout)
  local done, rerr, rres = false, nil, nil
  self:request(method, params, function(err, res)
    done, rerr, rres = true, err, res
  end)
  local ok = vim.wait(timeout or 20000, function()
    return done
  end, 5)
  if not ok then
    return nil, { code = "ETIMEDOUT", message = "the server did not answer in time (" .. method .. ")" }
  end
  if rerr then
    return nil, rerr
  end
  return rres
end

function M:on(event, fn)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], fn)
end

--- Fail everything in flight.
function M:close()
  if self.closed then
    return
  end
  self.closed = true
  local pending = self.pending
  self.pending = {}
  for _, cb in pairs(pending) do
    pcall(cb, CLOSED)
  end
end

return M
