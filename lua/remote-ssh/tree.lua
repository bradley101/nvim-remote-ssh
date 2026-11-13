-- A small file explorer for the remote workspace.
local api = vim.api
local P = require("remote-ssh.path")
local connection = require("remote-ssh.connection")
local config = require("remote-ssh.config")
local ui = require("remote-ssh.ui")
local log = require("remote-ssh.log")

local M = {}

-- bufnr -> { host, root, expanded = {path=true}, children = {path=entries}, nodes = {line -> node}, hidden }
M.trees = {}

local ns = api.nvim_create_namespace("remote-ssh-tree")

local function conn_for(t)
  local conn = connection.get(t.host)
  if conn and conn.state == "connected" then
    return conn
  end
  log.warn(("Not connected to '%s'."):format(t.host))
end

local function load(t, path)
  local conn = conn_for(t)
  if not conn then
    return nil
  end
  local res, err = conn:call("fs.list", { path = path })
  if err then
    log.error(("Cannot list %s: %s"):format(path, err.message or err.code))
    return nil
  end
  t.children[path] = res.entries
  return res.entries
end

local function render(bufnr)
  local t = M.trees[bufnr]
  if not t or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines, nodes, marks = { ("%s:%s"):format(t.host, t.root) }, {}, {}
  local function walk(dir, depth)
    local entries = t.children[dir] or load(t, dir)
    if not entries then
      return
    end
    for _, e in ipairs(entries) do
      if t.hidden or e.name:sub(1, 1) ~= "." then
        local path = P.join(dir, e.name)
        local is_dir = e.type == "directory"
        local marker = is_dir and (t.expanded[path] and "▾ " or "▸ ") or "  "
        local text = string.rep("  ", depth) .. marker .. e.name .. (is_dir and "/" or "") .. (e.link and " →" or "")
        lines[#lines + 1] = text
        nodes[#lines] = { path = path, type = e.type, name = e.name, dir = dir, depth = depth }
        if is_dir then
          marks[#marks + 1] = { #lines - 1, "Directory" }
        elseif e.type == "broken" then
          marks[#marks + 1] = { #lines - 1, "Comment" }
        end
        if is_dir and t.expanded[path] then
          walk(path, depth + 1)
        end
      end
    end
  end
  walk(t.root, 0)
  t.nodes = nodes
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  api.nvim_buf_add_highlight(bufnr, ns, "Title", 0, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_add_highlight(bufnr, ns, m[2], m[1], 0, -1)
  end
end

local function node_at_cursor(bufnr)
  local t = M.trees[bufnr]
  return t and t.nodes[api.nvim_win_get_cursor(0)[1]], t
end

local function refresh(bufnr, dir)
  local t = M.trees[bufnr]
  if dir then
    t.children[dir] = nil
  else
    t.children = {}
  end
  render(bufnr)
end

local function focus_path(bufnr, path)
  local t = M.trees[bufnr]
  for line, node in pairs(t.nodes) do
    if node.path == path then
      pcall(api.nvim_win_set_cursor, 0, { line, 0 })
      return
    end
  end
end

--- Open a file in a non-tree window.
local function open_file(t, path, how)
  local target
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  local function usable(win)
    return win ~= 0 and api.nvim_win_is_valid(win) and not M.trees[api.nvim_win_get_buf(win)] and vim.bo[api.nvim_win_get_buf(win)].buftype ~= "terminal"
  end
  if usable(prev) then
    target = prev
  else
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if usable(win) then
        target = win
        break
      end
    end
  end
  if target then
    api.nvim_set_current_win(target)
  else
    vim.cmd("botright vnew")
    local tree_win = vim.fn.bufwinid(vim.fn.bufnr(("rssh-tree://%s"):format(t.host)))
    if tree_win ~= -1 then
      api.nvim_win_set_width(tree_win, config.get().tree.width)
    end
  end
  vim.cmd(({ split = "split ", vsplit = "vsplit ", tab = "tabedit " })[how] or "edit " .. vim.fn.fnameescape(P.uri(t.host, path)))
  if how then
    vim.cmd("edit " .. vim.fn.fnameescape(P.uri(t.host, path)))
  end
end

local function target_dir(node, t)
  if not node then
    return t.root
  end
  if node.type == "directory" then
    return node.path
  end
  return node.dir
end

local actions = {}

function actions.open(bufnr, how)
  local node, t = node_at_cursor(bufnr)
  if not node then
    return
  end
  if node.type == "directory" then
    t.expanded[node.path] = not t.expanded[node.path] or nil
    if t.expanded[node.path] then
      t.children[node.path] = nil -- always show fresh contents when expanding
    end
    render(bufnr)
  elseif node.type == "broken" then
    log.warn(node.path .. " is a broken symbolic link.")
  else
    open_file(t, node.path, how)
  end
end

function actions.collapse(bufnr)
  local node, t = node_at_cursor(bufnr)
  if not node then
    return
  end
  if node.type == "directory" and t.expanded[node.path] then
    t.expanded[node.path] = nil
    render(bufnr)
  elseif node.dir ~= t.root then
    t.expanded[node.dir] = nil
    render(bufnr)
    focus_path(bufnr, node.dir)
  end
end

function actions.add(bufnr)
  local node, t = node_at_cursor(bufnr)
  local conn = conn_for(t)
  if not conn then
    return
  end
  local dir = target_dir(node, t)
  local name = ui.input(("New file in %s/ (end with / for a directory): "):format(dir), "")
  if not name or name == "" then
    return
  end
  local is_dir = name:sub(-1) == "/"
  local path = P.join(dir, name)
  local _, err
  if is_dir then
    _, err = conn:call("fs.mkdir", { path = path })
  else
    _, err = conn:call("fs.write", { path = path, data = "", expect_absent = true, mkdir = true })
  end
  if err then
    return log.error(("Could not create %s: %s"):format(path, err.message or err.code))
  end
  t.expanded[dir] = dir ~= t.root or nil
  local up = P.dirname(path)
  while #up > #dir do
    t.expanded[up] = true
    up = P.dirname(up)
  end
  refresh(bufnr)
  focus_path(bufnr, path)
  if not is_dir then
    open_file(t, path)
  end
end

--- Point open buffers at a renamed file.
local function retarget_buffers(host, from, to)
  local buffer = require("remote-ssh.buffer")
  for b, meta in pairs(buffer.meta) do
    if meta.host == host and api.nvim_buf_is_valid(b) then
      local new
      if meta.path == from then
        new = to
      elseif meta.path:sub(1, #from + 1) == from .. "/" then
        new = to .. meta.path:sub(#from + 1)
      end
      if new then
        meta.path = new
        pcall(api.nvim_buf_set_name, b, P.uri(host, new))
      end
    end
  end
end

function actions.rename(bufnr)
  local node, t = node_at_cursor(bufnr)
  local conn = node and conn_for(t)
  if not conn then
    return
  end
  local to = ui.input("Rename to: ", node.path)
  if not to or to == "" or to == node.path then
    return
  end
  to = to:sub(1, 1) == "/" and P.normalize(to) or P.join(node.dir, to)
  local _, err = conn:call("fs.rename", { from = node.path, to = to })
  if err then
    return log.error(("Could not rename %s: %s"):format(node.path, err.message or err.code))
  end
  retarget_buffers(t.host, node.path, to)
  refresh(bufnr)
  focus_path(bufnr, to)
end

function actions.copy(bufnr)
  local node, t = node_at_cursor(bufnr)
  local conn = node and conn_for(t)
  if not conn then
    return
  end
  local to = ui.input("Copy to: ", node.path)
  if not to or to == "" or to == node.path then
    return
  end
  to = to:sub(1, 1) == "/" and P.normalize(to) or P.join(node.dir, to)
  local _, err = conn:call("fs.copy", { from = node.path, to = to }, 120000)
  if err then
    return log.error(("Could not copy %s: %s"):format(node.path, err.message or err.code))
  end
  refresh(bufnr)
  focus_path(bufnr, to)
end

function actions.delete(bufnr)
  local node, t = node_at_cursor(bufnr)
  local conn = node and conn_for(t)
  if not conn then
    return
  end
  local what = node.type == "directory" and "directory and everything in it" or "file"
  if ui.confirm(("Delete this %s on '%s'?\n  %s\nThis cannot be undone."):format(what, t.host, node.path), { "Delete", "Cancel" }) ~= 1 then
    return
  end
  local _, err = conn:call("fs.remove", { path = node.path, recursive = true }, 120000)
  if err then
    return log.error(("Could not delete %s: %s"):format(node.path, err.message or err.code))
  end
  refresh(bufnr)
end

function actions.refresh(bufnr)
  refresh(bufnr)
end

function actions.up(bufnr)
  local t = M.trees[bufnr]
  local old = t.root
  t.root = P.dirname(t.root)
  t.expanded[old] = true
  refresh(bufnr)
  focus_path(bufnr, old)
end

function actions.cd(bufnr)
  local node, t = node_at_cursor(bufnr)
  if node and node.type == "directory" then
    t.root = node.path
    refresh(bufnr)
  end
end

function actions.toggle_hidden(bufnr)
  local t = M.trees[bufnr]
  t.hidden = not t.hidden
  render(bufnr)
end

function actions.yank(bufnr)
  local node = node_at_cursor(bufnr)
  if node then
    vim.fn.setreg('"', node.path)
    pcall(vim.fn.setreg, "+", node.path)
    api.nvim_echo({ { node.path } }, false, {})
  end
end

function actions.help()
  api.nvim_echo({
    { "<CR>/o open  s split  v vsplit  t tab  h collapse  a add  r rename  c copy  d delete\n" },
    { "R refresh  - parent  C set root  H hidden files  y yank path  q close  ? help" },
  }, false, {})
end

M.actions = actions

local keys = {
  ["<CR>"] = "open",
  o = "open",
  l = "open",
  ["<2-LeftMouse>"] = "open",
  h = "collapse",
  a = "add",
  r = "rename",
  c = "copy",
  d = "delete",
  R = "refresh",
  ["-"] = "up",
  C = "cd",
  H = "toggle_hidden",
  y = "yank",
  ["?"] = "help",
}

local function find_tree(host)
  for bufnr, t in pairs(M.trees) do
    if t.host == host and api.nvim_buf_is_valid(bufnr) then
      return bufnr, t
    end
  end
end

--- Open (or focus) the explorer for host rooted at `root`.
function M.open(host, root)
  root = P.normalize(root or "/")
  local bufnr, t = find_tree(host)
  if not bufnr then
    bufnr = api.nvim_create_buf(false, true)
    t = { host = host, root = root, expanded = {}, children = {}, nodes = {}, hidden = config.get().tree.show_hidden }
    M.trees[bufnr] = t
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "remote-ssh-tree"
    pcall(api.nvim_buf_set_name, bufnr, ("rssh-tree://%s"):format(host))
    for lhs, name in pairs(keys) do
      vim.keymap.set("n", lhs, function()
        actions[name](bufnr)
      end, { buffer = bufnr, nowait = true, silent = true })
    end
    vim.keymap.set("n", "s", function()
      actions.open(bufnr, "split")
    end, { buffer = bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "v", function()
      actions.open(bufnr, "vsplit")
    end, { buffer = bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "t", function()
      actions.open(bufnr, "tab")
    end, { buffer = bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "q", function()
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 and #api.nvim_tabpage_list_wins(0) > 1 then
        api.nvim_win_close(win, true)
      end
    end, { buffer = bufnr, nowait = true, silent = true })
    api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      callback = function()
        M.trees[bufnr] = nil
      end,
    })
  elseif t.root ~= root then
    t.root, t.children = root, {}
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    vim.cmd(("topleft vertical %dsplit"):format(config.get().tree.width))
    win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, bufnr)
    for opt, val in pairs({ number = false, relativenumber = false, wrap = false, winfixwidth = true, cursorline = true, signcolumn = "no", list = false }) do
      vim.wo[win][opt] = val
    end
  else
    api.nvim_set_current_win(win)
  end
  render(bufnr)
  return bufnr
end

function M.toggle(host, root)
  local bufnr = find_tree(host)
  local win = bufnr and vim.fn.bufwinid(bufnr) or -1
  if win ~= -1 and #api.nvim_tabpage_list_wins(0) > 1 then
    api.nvim_win_close(win, true)
  else
    M.open(host, root)
  end
end

--- Reveal `path` in the tree (expanding its parents).
function M.reveal(host, path)
  local bufnr, t = find_tree(host)
  if not bufnr or path:sub(1, #t.root) ~= t.root then
    return
  end
  local dir = P.dirname(path)
  while #dir > #t.root do
    t.expanded[dir] = true
    dir = P.dirname(dir)
  end
  render(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    api.nvim_win_call(win, function()
      focus_path(bufnr, path)
    end)
  end
end

M._render = render
return M
