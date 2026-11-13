-- Small shared helpers. Kept free of Neovim 0.10+ only APIs so the core can
-- be exercised on older builds too.
local M = {}

M.uv = vim.uv or vim.loop

--- Quote a string for a POSIX shell.
function M.shq(s)
  return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

function M.from_hex(hex)
  return (hex:gsub("%x%x", function(b)
    return string.char(tonumber(b, 16))
  end))
end

--- Parse "NVIM v0.11.5" / "0.11.5" / "v0.11.5-dev" into {major, minor, patch}.
function M.parse_version(s)
  if type(s) ~= "string" then
    return nil
  end
  local a, b, c = s:match("(%d+)%.(%d+)%.(%d+)")
  if not a then
    return nil
  end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

--- true when version string `have` >= `want`.
function M.version_ge(have, want)
  local h, w = M.parse_version(have), M.parse_version(want)
  if not h or not w then
    return false
  end
  for i = 1, 3 do
    if h[i] ~= w[i] then
      return h[i] > w[i]
    end
  end
  return true
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Last `n` non-empty lines of a blob of text, joined with newlines.
function M.tail(text, n)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  local from = math.max(1, #lines - (n or 5) + 1)
  return table.concat(lines, "\n", from)
end

-- ---------------------------------------------------------------------------
-- Minimal coroutine helpers: write multi-step flows top to bottom.
-- ---------------------------------------------------------------------------

--- Run `fn` in a coroutine. `done(err, ...)` is called when it returns or
--- throws. Inside, use M.await.
function M.async(fn, done)
  local co = coroutine.create(fn)
  local function step(...)
    local res = { coroutine.resume(co, ...) }
    if not res[1] then
      local err = res[2]
      if done then
        done(err)
      else
        vim.schedule(function()
          require("remote-ssh.log").error(debug.traceback(co, tostring(err)))
        end)
      end
      return
    end
    if coroutine.status(co) == "dead" then
      if done then
        done(nil, unpack(res, 2))
      end
      return
    end
    -- Yielded a function expecting a callback.
    local starter = res[2]
    local called = false
    starter(function(...)
      if called then
        return
      end
      called = true
      local args = { n = select("#", ...), ... }
      -- Always resume from the main loop so callers may use any API.
      vim.schedule(function()
        step(unpack(args, 1, args.n))
      end)
    end)
  end
  step()
end

--- Suspend the current coroutine until `starter(cb)` invokes cb; returns the
--- arguments passed to cb.
function M.await(starter)
  return coroutine.yield(starter)
end

--- Structured error used throughout: { kind = "...", message = "...", hint = "..." }
function M.err(kind, message, hint)
  return setmetatable({ kind = kind, message = message, hint = hint }, {
    __tostring = function(e)
      return e.hint and (e.message .. "\n" .. e.hint) or e.message
    end,
  })
end

function M.errmsg(e)
  if type(e) == "table" then
    if e.message then
      return e.hint and (e.message .. "\n" .. e.hint) or e.message
    end
    return vim.inspect(e)
  end
  return tostring(e)
end

return M
