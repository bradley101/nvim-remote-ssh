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
  return nil
end

--- Start a new Neovim that opens `path` on `host`. Returns true, or false and
--- a reason.
function M.spawn(host, path)
  local cmd = M.detect()
  if not cmd then
    return false, "no way to open a new terminal window is known (set open.cmd)"
  end
  local argv = {
    vim.v.progpath,
    "-c",
    ("lua require('remote-ssh').open(%q, %s, { window = 'same' })"):format(host, path and ("%q"):format(path) or "nil"),
  }
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
  if require("remote-ssh.connection").get(host) or not M.has_local_buffers() then
    return "same"
  end
  local cmd, what = M.detect()
  if not cmd then
    return "same"
  end
  if mode == "ask" then
    local choice = require("remote-ssh.ui").confirm(
      ("Local files are open here. Open '%s' in:"):format(host),
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
