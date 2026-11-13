-- Modal dialogs (password, text input, multiple choice) drawn in a floating
-- window over a dimmed background, so a prompt cannot be overlooked.
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("remote-ssh-dialog")

local function ui_cfg()
  return require("remote-ssh.config").get().ui
end

--- true when dialogs can be drawn (a UI is attached and they are enabled).
function M.available()
  return ui_cfg().dialogs ~= false and #api.nvim_list_uis() > 0
end

local function set_hl()
  api.nvim_set_hl(0, "RemoteSSHBackdrop", { bg = "#000000", default = true })
  api.nvim_set_hl(0, "RemoteSSHDialogField", { link = "CursorLine", default = true })
  api.nvim_set_hl(0, "RemoteSSHDialogChoice", { link = "PmenuSel", default = true })
  api.nvim_set_hl(0, "RemoteSSHDialogHint", { link = "Comment", default = true })
end

-- ---------------------------------------------------------------------------
-- Dimmed background
-- ---------------------------------------------------------------------------

local backdrop = { holders = {} }

local function backdrop_sync()
  local dim = ui_cfg().dim
  local wanted = next(backdrop.holders) ~= nil and type(dim) == "number" and dim > 0 and vim.o.termguicolors
  if not wanted then
    if backdrop.win and api.nvim_win_is_valid(backdrop.win) then
      pcall(api.nvim_win_close, backdrop.win, true)
    end
    backdrop.win = nil
    return
  end
  if backdrop.win and api.nvim_win_is_valid(backdrop.win) then
    return
  end
  set_hl()
  if not (backdrop.buf and api.nvim_buf_is_valid(backdrop.buf)) then
    backdrop.buf = api.nvim_create_buf(false, true)
    vim.bo[backdrop.buf].bufhidden = "hide"
  end
  backdrop.win = api.nvim_open_win(backdrop.buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 190,
  })
  vim.wo[backdrop.win].winhighlight = "Normal:RemoteSSHBackdrop"
  vim.wo[backdrop.win].winblend = math.max(0, math.min(100, 100 - math.floor(dim)))
end

--- Dim everything behind our windows while `who` needs it.
function M.dim(who, on)
  backdrop.holders[who] = on and true or nil
  pcall(backdrop_sync)
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local function wrap(text, width)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("%s+$", "")
    if line == "" then
      out[#out + 1] = ""
    end
    while line ~= "" do
      if vim.fn.strdisplaywidth(line) <= width then
        out[#out + 1] = line
        break
      end
      local cut = width
      local head = vim.fn.strcharpart(line, 0, width)
      local space = head:match("^.*()%s")
      if space and space > 1 then
        out[#out + 1] = head:sub(1, space - 1)
        line = line:sub(space + 1):gsub("^%s+", "")
      else
        out[#out + 1] = head
        line = vim.fn.strcharpart(line, cut)
      end
    end
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

local function key(s)
  return api.nvim_replace_termcodes(s, true, true, true)
end

local KEYS

local function keys()
  KEYS = KEYS
    or {
      cr = key("<CR>"),
      nl = key("<NL>"),
      kenter = key("<kEnter>"),
      esc = key("<Esc>"),
      bs = key("<BS>"),
      del = key("<Del>"),
      cu = key("<C-u>"),
      cw = key("<C-w>"),
      ch = key("<C-h>"),
      left = key("<Left>"),
      right = key("<Right>"),
      tab = key("<Tab>"),
      stab = key("<S-Tab>"),
    }
  return KEYS
end

--- Draw `body` (text), then the lines produced by `footer(width)`, and run
--- `on_key(k)` for every key until it returns a result table { value = ... }.
local function run(spec)
  set_hl()
  local width = math.max(math.min(vim.o.columns - 8, 72), 20)
  local body = wrap(spec.text or "", width - 4)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win

  local function draw()
    local lines, marks = { "" }, {}
    for _, l in ipairs(body) do
      lines[#lines + 1] = "  " .. l
    end
    lines[#lines + 1] = ""
    spec.render(lines, marks, width)
    lines[#lines + 1] = ""
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks) do
      pcall(api.nvim_buf_set_extmark, buf, ns, m.row, m.col or 0, {
        end_row = m.end_col and m.row or m.row + 1,
        end_col = m.end_col or 0,
        hl_group = m.hl,
        hl_eol = m.end_col == nil,
      })
    end
    local cfg = {
      relative = "editor",
      width = width,
      height = #lines,
      row = math.max(math.floor((vim.o.lines - #lines) / 2) - 1, 0),
      col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    }
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_set_config(win, cfg)
    else
      cfg.style = "minimal"
      cfg.border = "rounded"
      cfg.focusable = false
      cfg.noautocmd = true
      cfg.zindex = 210
      cfg.title = " " .. (spec.title or "Remote SSH") .. " "
      cfg.title_pos = "center"
      win = api.nvim_open_win(buf, false, cfg)
      vim.wo[win].winhighlight = "Normal:NormalFloat"
      vim.wo[win].wrap = false
    end
    vim.cmd("redraw")
  end

  -- Pasted text must reach the dialog, never the buffer underneath.
  local saved_paste = vim.paste
  local pasted = false
  vim.paste = function(lines)
    if spec.on_paste then
      spec.on_paste(table.concat(lines, " "))
    end
    pasted = true
    return true
  end
  M.dim("dialog", true)

  local result
  local ok, err = pcall(function()
    local dirty = true
    while not result do
      if dirty then
        draw()
        dirty = false
      end
      -- Poll rather than block, so pasted text (which arrives as an event,
      -- not as keys) shows up at once.
      local got, k = pcall(vim.fn.getcharstr, 0)
      if not got then
        result = { value = nil } -- interrupted with CTRL-C
      elseif k ~= "" then
        result = spec.on_key(k)
        dirty = true
      else
        got = pcall(vim.wait, 15, function()
          return pasted
        end, 5)
        if not got then
          result = { value = nil }
        end
        if pasted then
          pasted, dirty = false, true
        end
      end
    end
  end)

  vim.paste = saved_paste
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  M.dim("dialog", false)
  pcall(vim.cmd, "redraw")
  if not ok then
    error(err, 0)
  end
  return result.value
end

-- ---------------------------------------------------------------------------
-- Dialogs
-- ---------------------------------------------------------------------------

local function text_dialog(spec, secret)
  local K = keys()
  local chars = {}
  for _, c in ipairs(vim.fn.split(spec.default or "", "\\zs")) do
    chars[#chars + 1] = c
  end
  local function add(text)
    for _, c in ipairs(vim.fn.split(text, "\\zs")) do
      if c:byte() >= 32 and c ~= "\127" then
        chars[#chars + 1] = c
      end
    end
  end
  return run({
    title = spec.title,
    text = spec.text,
    on_paste = add,
    render = function(lines, marks, width)
      local shown = secret and string.rep("•", #chars) or table.concat(chars)
      local room = width - 6
      local n = vim.fn.strchars(shown)
      if n > room then
        shown = "…" .. vim.fn.strcharpart(shown, n - room + 1)
      end
      lines[#lines + 1] = "  " .. shown .. "█"
      marks[#marks + 1] = { row = #lines - 1, hl = "RemoteSSHDialogField" }
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  Enter: confirm   Esc: cancel"
      marks[#marks + 1] = { row = #lines - 1, hl = "RemoteSSHDialogHint" }
    end,
    on_key = function(k)
      if k == K.cr or k == K.nl or k == K.kenter then
        return { value = table.concat(chars) }
      elseif k == K.esc then
        return { value = nil }
      elseif k == K.bs or k == K.ch or k == K.del then
        chars[#chars] = nil
      elseif k == K.cu then
        chars = {}
      elseif k == K.cw then
        while #chars > 0 and chars[#chars]:match("%s") do
          chars[#chars] = nil
        end
        while #chars > 0 and not chars[#chars]:match("[%s/]") do
          chars[#chars] = nil
        end
      elseif k:byte() ~= 128 then -- not a special key (arrows, mouse, ...)
        add(k)
      end
    end,
  })
end

--- Ask for a password or other secret; the text is never shown.
--- Returns the string, or nil when cancelled.
function M.secret(prompt, opts)
  return text_dialog({ title = opts and opts.title or "Password required", text = prompt }, true)
end

--- Ask for a line of text. Returns the string, or nil when cancelled.
function M.input(prompt, default, opts)
  return text_dialog({ title = opts and opts.title, text = prompt, default = default }, false)
end

--- Multiple choice. Returns the 1-based index, or 0 when cancelled.
function M.confirm(msg, choices, opts)
  local K = keys()
  local sel = 1
  -- A letter picks the choice when exactly one choice starts with it.
  local by_letter = {}
  for i, c in ipairs(choices) do
    local l = c:sub(1, 1):lower()
    by_letter[l] = by_letter[l] == nil and i or false
  end
  return run({
    title = opts and opts.title,
    text = msg,
    render = function(lines, marks)
      local line = " "
      local row = #lines
      for i, c in ipairs(choices) do
        local label = "  " .. c .. "  "
        if i == sel then
          marks[#marks + 1] = { row = row, col = #line, end_col = #line + #label, hl = "RemoteSSHDialogChoice" }
        end
        line = line .. label .. " "
      end
      lines[#lines + 1] = line
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  ←/→: move   Enter: select   Esc: cancel"
      marks[#marks + 1] = { row = #lines - 1, hl = "RemoteSSHDialogHint" }
    end,
    on_key = function(k)
      if k == K.cr or k == K.nl or k == K.kenter then
        return { value = sel }
      elseif k == K.esc then
        return { value = 0 }
      elseif k == K.right or k == K.tab then
        sel = sel % #choices + 1
      elseif k == K.left or k == K.stab then
        sel = (sel - 2) % #choices + 1
      elseif by_letter[k:lower()] then
        return { value = by_letter[k:lower()] }
      end
    end,
  }) or 0
end

return M
