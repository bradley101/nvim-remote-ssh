-- Opening a remote workspace in a Neovim of its own, so it does not share
-- windows, buffers and the working directory with local work.
local api = vim.api

local M = {}

--- true when this Neovim has local files open (or unsaved scratch text).
function M.has_local_buffers()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and vim.bo[b].buftype == "" then
      local name = api.nvim_buf_get_name(b)
      if name == "" then
        if vim.bo[b].modified then
          return true
        end
      elseif not name:match("^%a[%w+.-]*://") then
        return true
      end
    end
  end
  return false
end

--- true when this Neovim is already used for another remote host.
function M.has_other_remote(host)
  for h in pairs(require("remote-ssh").workspaces) do
    if h ~= host then
      return true
    end
  end
  for h, conn in pairs(require("remote-ssh.connection").conns) do
    if h ~= host and conn.state ~= "disconnected" then
      return true
    end
  end
  return false
end

--- Run argv in a new window of a macOS terminal app through AppleScript.
local function applescript(script)
  return function(argv)
    local parts = {}
    for i, a in ipairs(argv) do
      parts[i] = require("remote-ssh.util").shq(a)
    end
    local cmd = ("exec " .. table.concat(parts, " ")):gsub("\\", "\\\\"):gsub('"', '\\"')
    local job = vim.fn.jobstart({ "osascript", "-e", (script:gsub("{cmd}", function()
      return cmd
    end)) }, { detach = true })
    if job <= 0 then
      error("could not run osascript")
    end
  end
end

--- The command prefix that runs a program in a new terminal window, and a
--- name for it; nil when none is known.
function M.detect()
  local cmd = require("remote-ssh.config").get().open.cmd
  if cmd then
    return cmd, "a new window"
  end
  if #api.nvim_list_uis() == 0 then
    return nil
  end
  local function has(exe)
    return vim.fn.executable(exe) == 1
  end
  local env = vim.env
  if env.TMUX and has("tmux") then
    return { "tmux", "new-window", "--" }, "a new tmux window"
  end
  if env.WEZTERM_PANE and has("wezterm") then
    return { "wezterm", "cli", "spawn", "--new-window", "--" }, "a new WezTerm window"
  end
  if env.KITTY_WINDOW_ID and has("kitty") then
    return { "kitty", "--detach", "--" }, "a new kitty window"
  end
  if env.ALACRITTY_WINDOW_ID and has("alacritty") then
    return { "alacritty", "-e" }, "a new Alacritty window"
  end
  if env.TERM_PROGRAM == "iTerm.app" and has("osascript") then
    return applescript(
      'tell application "iTerm2"\nset w to (create window with default profile)\ntell current session of w to write text "{cmd}"\nend tell'
    ), "a new iTerm2 window"
  end
  if env.TERM_PROGRAM == "Apple_Terminal" and has("osascript") then
    return applescript('tell application "Terminal"\nactivate\ndo script "{cmd}"\nend tell'), "a new Terminal window"
  end
  return nil
end

--- Start a new Neovim that opens `path` on `host`. Returns true, or false and
--- a reason.
function M.spawn(host, path)
  local cmd = M.detect()
  if not cmd then
    return false, "no way to open a new terminal window is known (set open.cmd)"
  end
  local uri = "rssh-open://" .. host
  if path then
    uri = uri .. (path:sub(1, 1) == "/" and "" or "/") .. path
  end
  local argv = { vim.v.progpath, uri }
  if vim.env.NVIM_APPNAME and vim.env.NVIM_APPNAME ~= "" then
    -- A terminal multiplexer starts programs with its own environment.
    argv = { "env", "NVIM_APPNAME=" .. vim.env.NVIM_APPNAME, unpack(argv) }
  end
  if type(cmd) == "function" then
    local ok, err = pcall(cmd, argv)
    if not ok or err == false then
      return false, ok and "open.cmd declined" or tostring(err)
    end
    return true
  end
  local full = vim.list_extend(vim.deepcopy(cmd), argv)
  local ok, job = pcall(vim.fn.jobstart, full, { detach = true })
  if not ok or job <= 0 then
    return false, ("could not run '%s'"):format(tostring(cmd[1]))
  end
  return true
end

--- Decide where `host` should be opened: "new" (already started in a new
--- Neovim), "same", or nil when the user cancelled.
function M.place(host, path, opts)
  local mode = (opts and opts.window) or require("remote-ssh.config").get().open.window
  if mode == "same" or mode == "never" or mode == false then
    return "same"
  end
  local conn = require("remote-ssh.connection").get(host)
  if conn and conn.state ~= "disconnected" then
    return "same"
  end
  local other = M.has_other_remote(host)
  if not other and not M.has_local_buffers() then
    return "same"
  end
  local cmd, what = M.detect()
  if not cmd then
    if not M.warned and #api.nvim_list_uis() > 0 then
      M.warned = true
      require("remote-ssh.log").info(
        ("Opening '%s' in this Neovim: no way to open a new terminal window is known for this terminal. Set open.cmd to get a separate window."):format(host)
      )
    end
    return "same"
  end
  if mode == "ask" then
    local choice = require("remote-ssh.ui").confirm(
      ("%s here. Open '%s' in:"):format(other and "Another remote host is open" or "Local files are open", host),
      { "New window", "This window", "Cancel" }
    )
    if choice == 2 then
      return "same"
    elseif choice ~= 1 then
      return nil
    end
  end
  local ok, why = M.spawn(host, path)
  if not ok then
    require("remote-ssh.log").warn(("Opening '%s' here: %s."):format(host, why))
    return "same"
  end
  require("remote-ssh.log").info(("Opened '%s' in %s."):format(host, what))
  return "new"
end

return M
