-- In-memory log (viewable with :RemoteSSH log) plus user notifications.
local M = {}

local MAX = 2000
M.lines = {}

local function add(level, msg)
  local stamp = os.date("%H:%M:%S")
  for line in tostring(msg):gmatch("[^\n]+") do
    M.lines[#M.lines + 1] = string.format("%s [%s] %s", stamp, level, line)
  end
  while #M.lines > MAX do
    table.remove(M.lines, 1)
  end
end

local function notify(msg, level)
  local cfg = require("remote-ssh.config").get()
  local fn = cfg.ui.notify or vim.notify
  local function emit()
    fn(msg, level, { title = "remote-ssh" })
  end
  if vim.in_fast_event() then
    vim.schedule(emit)
  else
    emit()
  end
end

--- Log only.
function M.debug(msg)
  add("debug", msg)
end

function M.info(msg)
  add("info", msg)
  notify(msg, vim.log.levels.INFO)
end

function M.warn(msg)
  add("warn", msg)
  notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  add("error", msg)
  notify(msg, vim.log.levels.ERROR)
end

function M.show()
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "remote-ssh://log")
  vim.cmd("normal! G")
end

return M
