-- File listing and text search, executed on the server.
local config = require("remote-ssh.config")
local P = require("remote-ssh.path")

local M = {}

local function tool(conn, name)
  conn.tools = conn.tools or {}
  if conn.tools[name] == nil then
    local res = conn:call("which", { names = { name } })
    conn.tools[name] = (res and res[name] and res[name] ~= vim.NIL) and res[name] or false
  end
  return conn.tools[name]
end

--- Path of a tool on the server (cached per connection), or false.
M.tool = tool

local function strip(line)
  if line:sub(1, 2) == "./" then
    return line:sub(3)
  end
  return line
end

--- List files under root (relative paths). cb(err, files, truncated).
function M.files(conn, root, cb)
  local max = config.get().search.max_files
  local cmd
  if tool(conn, "rg") then
    cmd = { "rg", "--files", "--hidden", "--glob", "!.git", "--color", "never", "." }
  else
    cmd = { "find", ".", "-type", "d", "(", "-name", ".git", "-o", "-name", "node_modules", ")", "-prune", "-o", "-type", "f", "-print" }
  end
  conn:request("exec", { cmd = cmd, cwd = root, timeout = 60000, max_bytes = max * 120 }, function(err, res)
    if err then
      return cb(err)
    end
    local files = {}
    for line in res.stdout:gmatch("[^\n]+") do
      files[#files + 1] = strip(line)
      if #files >= max then
        break
      end
    end
    if res.truncated then
      files[#files] = nil -- possibly cut mid-line
    end
    if #files == 0 and res.code ~= 0 and res.stderr ~= "" then
      return cb({ code = "ESEARCH", message = res.stderr })
    end
    cb(nil, files, res.truncated or res.timed_out or #files >= max)
  end)
end

--- Parse one line of grep output: file:line[:col]:text
function M.parse_grep_line(line, has_col)
  local file, lnum, col, text
  if has_col then
    file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
  else
    file, lnum, text = line:match("^(.-):(%d+):(.*)$")
  end
  if not file then
    return nil
  end
  return { file = strip(file), lnum = tonumber(lnum), col = tonumber(col) or 1, text = text }
end

--- Streaming text search. on_results(list of {file,lnum,col,text}) is called
--- as matches arrive; on_done({truncated, error}) once. Returns a handle with
--- cancel().
function M.grep(conn, root, pattern, opts, on_results, on_done)
  opts = opts or {}
  local max = opts.max or config.get().search.max_grep_results
  local has_col = tool(conn, "rg") and true or false
  local cmd
  if has_col then
    cmd = { "rg", "--vimgrep", "--no-heading", "--color", "never", "--smart-case", "--hidden", "--glob", "!.git", "--max-columns", "400" }
    if opts.fixed then
      cmd[#cmd + 1] = "--fixed-strings"
    end
    vim.list_extend(cmd, opts.args or {})
    vim.list_extend(cmd, { "-e", pattern, "." })
  else
    cmd = { "grep", "-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", opts.fixed and "-F" or "-E" }
    if pattern:lower() == pattern then
      cmd[#cmd + 1] = "-i"
    end
    vim.list_extend(cmd, { "-e", pattern, "." })
  end

  local pending, count, finished, stderr = "", 0, false, ""
  local handle
  local function finish(info)
    if finished then
      return
    end
    finished = true
    on_done(info or {})
  end
  local function consume(final)
    local batch = {}
    while true do
      local nl = pending:find("\n", 1, true)
      local line
      if nl then
        line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
      elseif final and pending ~= "" then
        line, pending = pending, ""
      else
        break
      end
      local item = M.parse_grep_line(line, has_col)
      if item then
        count = count + 1
        batch[#batch + 1] = item
        if count >= max then
          break
        end
      end
    end
    if #batch > 0 and not finished then
      on_results(batch)
    end
    if count >= max and not finished then
      handle.kill("sigkill")
      finish({ truncated = true })
    end
  end
  handle = conn:spawn(cmd, {
    cwd = root,
    on_stdout = function(data)
      if finished then
        return
      end
      pending = pending .. data
      consume(false)
    end,
    on_stderr = function(data)
      if #stderr < 2000 then
        stderr = stderr .. data
      end
    end,
    on_exit = function(code)
      if finished then
        return
      end
      consume(true)
      -- grep/rg: 0 = matches, 1 = none, 2+ = error (often a bad pattern).
      if code and code >= 2 and count == 0 then
        finish({ error = vim.trim(stderr) ~= "" and vim.trim(stderr) or ("search failed (exit " .. code .. ")") })
      else
        finish({})
      end
    end,
  }, function(err, h)
    if err then
      finish({ error = err.message or err.code })
    else
      h.close_stdin()
    end
  end)
  return {
    cancel = function()
      if not finished then
        finished = true
        handle.kill("sigkill")
      end
    end,
  }
end

--- Search and put the matches in the quickfix list (works without telescope).
function M.grep_to_quickfix(conn, root, pattern, cb)
  local items = {}
  M.grep(conn, root, pattern, {}, function(batch)
    for _, r in ipairs(batch) do
      items[#items + 1] = { filename = P.uri(conn.host, P.join(root, r.file)), lnum = r.lnum, col = r.col, text = r.text }
    end
  end, function(info)
    vim.fn.setqflist({}, " ", { title = ("remote-ssh grep: %s (%s)"):format(pattern, conn.host), items = items })
    if cb then
      cb(info, items)
    end
  end)
end

return M
