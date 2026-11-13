-- A small floating window that shows what a connection attempt is doing, so
-- slow steps (several jump hosts, authentication, first-time setup) are not
-- mistaken for a hang.
local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- host -> { text, since }
local items = {}
local order = {}
local buf, win, timer
local frame = 1
local suspended = 0

local function enabled()
  return require("remote-ssh.config").get().ui.progress ~= false
end

local function lines()
  local out = {}
  for _, host in ipairs(order) do
    local it = items[host]
    local secs = math.floor((uv.now() - it.since) / 1000)
    out[#out + 1] = (" %s %s "):format(FRAMES[frame], host)
    out[#out + 1] = ("   %s…%s "):format(it.text, secs >= 3 and (" (%ds)"):format(secs) or "")
  end
  return out
end

local function close_win()
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  win = nil
  require("remote-ssh.dialog").dim("progress", false)
end

local function flush()
  -- Connecting often happens while Neovim is blocked in a wait loop or still
  -- starting up, where the screen is not redrawn on its own.
  if api.nvim__redraw and win and api.nvim_win_is_valid(win) then
    if pcall(api.nvim__redraw, { win = win, flush = true }) then
      return
    end
  end
  pcall(vim.cmd, "redraw")
end

local function render()
  if #order == 0 or suspended > 0 or not enabled() then
    if win then
      close_win()
      flush()
    end
    return
  end
  local text = lines()
  local width = 30
  for _, l in ipairs(text) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(vim.o.columns - 4, 10))
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  local cfg = {
    relative = "editor",
    width = width,
    height = #text,
    row = math.max(math.floor((vim.o.lines - #text) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
  }
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_config(win, cfg)
  else
    cfg.style = "minimal"
    cfg.border = "rounded"
    cfg.focusable = false
    cfg.noautocmd = true
    cfg.zindex = 200
    if vim.fn.has("nvim-0.9") == 1 then
      cfg.title = " Remote SSH "
      cfg.title_pos = "center"
    end
    require("remote-ssh.dialog").dim("progress", true)
    win = api.nvim_open_win(buf, false, cfg)
    vim.wo[win].winhighlight = "Normal:NormalFloat"
    vim.wo[win].wrap = false
  end
  flush()
end

local function safe_render()
  local ok, err = pcall(render)
  if not ok then
    require("remote-ssh.log").debug("progress window: " .. tostring(err))
  end
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function start_timer()
  if timer then
    return
  end
  timer = uv.new_timer()
  timer:start(120, 120, vim.schedule_wrap(function()
    if #order == 0 then
      return stop_timer()
    end
    frame = frame % #FRAMES + 1
    safe_render()
  end))
end

--- Show `text` for `host`; nil removes the host (and closes the window when
--- it was the last one).
function M.set(host, text)
  if text then
    if not items[host] then
      items[host] = { since = uv.now() }
      order[#order + 1] = host
    end
    items[host].text = text
    if enabled() then
      start_timer()
    end
  elseif items[host] then
    items[host] = nil
    for i, h in ipairs(order) do
      if h == host then
        table.remove(order, i)
        break
      end
    end
    if #order == 0 then
      stop_timer()
    end
  end
  if vim.in_fast_event() then
    vim.schedule(safe_render)
  else
    safe_render()
  end
end

--- Hide the window while a prompt is on screen, so it never covers it.
function M.suspend()
  suspended = suspended + 1
  safe_render()
end

function M.resume()
  suspended = math.max(suspended - 1, 0)
  safe_render()
end

--- What is being shown, for tests and statuslines: host -> text.
function M.status()
  local out = {}
  for host, it in pairs(items) do
    out[host] = it.text
  end
  return out
end

function M.visible()
  return win ~= nil and api.nvim_win_is_valid(win)
end

return M
