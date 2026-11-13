-- Thin local process wrapper over libuv with binary-safe streams.
local util = require("remote-ssh.util")
local uv = util.uv

local M = {}

local function build_env(extra)
  local env = uv.os_environ()
  for k, v in pairs(extra or {}) do
    env[k] = v
  end
  local list = {}
  for k, v in pairs(env) do
    list[#list + 1] = k .. "=" .. v
  end
  return list
end

--- Spawn a process.
--- opts: env (map, merged over the current environment), on_stdout(chunk),
--- on_stderr(chunk), on_exit(code, signal). Stream callbacks run in a fast
--- context; on_exit runs after both output streams are drained.
--- Returns a handle { write, close_stdin, kill, pid } or nil, err.
function M.spawn(cmd, args, opts)
  opts = opts or {}
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local h = { exited = false }
  local open_streams = 2
  local exit_code, exit_signal
  local finished = false
  local grace

  local function finish()
    if finished then
      return
    end
    finished = true
    if grace and not grace:is_closing() then
      grace:close()
    end
    for _, p in ipairs({ stdin, stdout, stderr }) do
      if not p:is_closing() then
        p:close()
      end
    end
    if opts.on_exit then
      opts.on_exit(exit_code, exit_signal)
    end
  end

  local function maybe_finish()
    if h.exited and open_streams == 0 then
      finish()
    end
  end

  local handle, pid = uv.spawn(cmd, {
    args = args,
    stdio = { stdin, stdout, stderr },
    env = build_env(opts.env),
    cwd = opts.cwd,
    -- Own session: no controlling terminal, so ssh never prompts on the TTY
    -- that Neovim's UI is using.
    detached = true,
  }, function(code, signal)
    h.exited = true
    exit_code, exit_signal = code, signal
    if h.handle and not h.handle:is_closing() then
      h.handle:close()
    end
    -- A backgrounded child (ssh ControlPersist master) may keep our pipes
    -- open; do not wait for EOF forever.
    if open_streams > 0 then
      grace = uv.new_timer()
      grace:start(300, 0, finish)
    else
      finish()
    end
  end)

  if not handle then
    for _, p in ipairs({ stdin, stdout, stderr }) do
      p:close()
    end
    return nil, tostring(pid)
  end
  h.handle, h.pid = handle, pid

  local function reader(pipe, cb)
    pipe:read_start(function(err, chunk)
      if chunk and cb then
        cb(chunk)
      end
      if err or not chunk then
        open_streams = open_streams - 1
        pipe:read_stop()
        maybe_finish()
      end
    end)
  end
  reader(stdout, opts.on_stdout)
  reader(stderr, opts.on_stderr)

  function h.write(data)
    if not stdin:is_closing() then
      stdin:write(data)
    end
  end

  function h.close_stdin()
    if not stdin:is_closing() then
      stdin:shutdown(function()
        if not stdin:is_closing() then
          stdin:close()
        end
      end)
    end
  end

  function h.kill(signal)
    if not h.exited then
      pcall(uv.kill, pid, signal or "sigterm")
    end
  end

  return h
end

--- Run to completion, collecting output. cb({code, signal, stdout, stderr}).
--- opts.stdin: string written to stdin (stdin is always closed afterwards).
--- opts.timeout: ms; the process is killed and code is -1 on expiry.
function M.run(cmd, args, opts, cb)
  opts = opts or {}
  local out, err = {}, {}
  local timer
  local timed_out = false
  local h, spawn_err = M.spawn(cmd, args, {
    env = opts.env,
    cwd = opts.cwd,
    on_stdout = function(c)
      out[#out + 1] = c
      if opts.on_stdout then
        opts.on_stdout(c)
      end
    end,
    on_stderr = function(c)
      err[#err + 1] = c
    end,
    on_exit = function(code, signal)
      if timer and not timer:is_closing() then
        timer:close()
      end
      vim.schedule(function()
        cb({
          code = timed_out and -1 or code,
          signal = signal,
          timed_out = timed_out,
          stdout = table.concat(out),
          stderr = table.concat(err),
        })
      end)
    end,
  })
  if not h then
    vim.schedule(function()
      cb({ code = -2, stdout = "", stderr = spawn_err, spawn_failed = true })
    end)
    return nil
  end
  if opts.stdin then
    h.write(opts.stdin)
  end
  h.close_stdin()
  if opts.timeout then
    timer = uv.new_timer()
    timer:start(opts.timeout, 0, function()
      timed_out = true
      h.kill("sigkill")
    end)
  end
  return h
end

return M
