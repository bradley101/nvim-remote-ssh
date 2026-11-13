-- Public API. Everything the :RemoteSSH command does is available here.
local api = vim.api

local M = {}

--- host -> workspace root opened on that host.
M.workspaces = {}
--- Most recently used { host, root }.
M.current = nil

local did_setup = false

local function mod(name)
  return require("remote-ssh." .. name)
end

function M.setup(opts)
  if opts or not did_setup then
    mod("config").setup(opts)
  end
  if did_setup then
    return
  end
  did_setup = true
  mod("buffer").setup()
  mod("lsp").setup()
  mod("forward").setup()
  api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup("RemoteSSHExit", { clear = true }),
    callback = function()
      mod("connection").close_all()
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Context helpers
-- ---------------------------------------------------------------------------

--- Workspace root containing `path` on host, if any.
function M.workspace_for(host, path)
  local root = M.workspaces[host]
  if root and (path == root or root == "/" or path:sub(1, #root + 1) == root .. "/") then
    return root
  end
  return nil
end

--- Host and directory the current window is about: (host, root) or nil.
function M.context()
  local buf = api.nvim_get_current_buf()
  local meta = mod("buffer").meta[buf]
  if meta then
    return meta.host, M.workspaces[meta.host] or mod("path").dirname(meta.path)
  end
  local tree = mod("tree").trees[buf]
  if tree then
    return tree.host, M.workspaces[tree.host] or tree.root
  end
  if M.current then
    return M.current.host, M.current.root
  end
  return nil
end

--- Connected Conn + root for the current context, or nil after telling the
--- user what to do.
local function need_context()
  local host, root = M.context()
  if not host then
    mod("log").warn("No remote workspace is open. Use :RemoteSSH open")
    return nil
  end
  local conn = mod("connection").get(host)
  if not conn or conn.state ~= "connected" then
    mod("log").warn(("Not connected to '%s'. Use :RemoteSSH reconnect"):format(host))
    return nil
  end
  return conn, root
end

local function has_telescope()
  return pcall(require, "telescope")
end

-- ---------------------------------------------------------------------------
-- Connecting and workspaces
-- ---------------------------------------------------------------------------

--- Let the user choose a host from their ssh config. cb(host).
function M.pick_host(cb)
  if has_telescope() then
    return mod("telescope").hosts({ on_choice = cb })
  end
  local hosts = mod("ssh_config").hosts()
  local OTHER = "Other host..."
  hosts[#hosts + 1] = OTHER
  vim.ui.select(hosts, { prompt = "Connect to SSH host" }, function(choice)
    if choice == OTHER then
      choice = mod("ui").input("SSH host (alias or user@host): ", "")
    end
    if choice and choice ~= "" then
      cb(choice)
    end
  end)
end

--- Connect (running first-time setup if needed). cb(err, conn).
function M.connect(host, cb)
  M.setup()
  if not host or host == "" then
    return M.pick_host(function(h)
      M.connect(h, cb)
    end)
  end
  mod("connection").connect(host, {}, function(err, conn)
    if not err and not cb then
      mod("log").info(("Connected to '%s'."):format(host))
    end
    if cb then
      cb(err, conn)
    end
  end)
end

local function ask_folder(conn, default)
  local ui, P = mod("ui"), mod("path")
  while true do
    local answer = ui.input(("Folder to open on '%s': "):format(conn.host), default)
    if not answer or vim.trim(answer) == "" then
      return nil
    end
    answer = vim.trim(answer)
    if answer:sub(1, 1) == "~" then
      answer = conn.home .. answer:sub(2)
    elseif answer:sub(1, 1) ~= "/" then
      answer = conn.home .. "/" .. answer
    end
    local path = P.normalize(answer)
    local res, err = conn:call("fs.stat", { path = path })
    if err then
      mod("log").error(("Could not check %s: %s"):format(path, err.message or err.code))
      return nil
    end
    local stat = res.stat ~= vim.NIL and res.stat or nil
    if stat and stat.type == "directory" then
      return path
    end
    mod("log").warn(stat and (path .. " is not a folder.") or (path .. " does not exist on '" .. conn.host .. "'."))
    default = path
  end
end

--- Open a folder on a host as the workspace: connect, remember it, show the
--- explorer. host/path are prompted for when omitted.
function M.open(host, path)
  M.setup()
  if not host or host == "" then
    return M.pick_host(function(h)
      M.open(h, path)
    end)
  end
  M.connect(host, function(err, conn)
    if err then
      return
    end
    local P, state = mod("path"), mod("state")
    local root
    if path and path ~= "" then
      if path:sub(1, 1) == "~" then
        path = conn.home .. path:sub(2)
      end
      root = P.normalize(path)
      local res, serr = conn:call("fs.stat", { path = root })
      local stat = res and res.stat ~= vim.NIL and res.stat or nil
      if serr or not stat or stat.type ~= "directory" then
        mod("log").warn(("%s is not a folder on '%s'."):format(root, host))
        root = ask_folder(conn, root)
      end
    else
      local last
      for _, r in ipairs(state.recent()) do
        if r.host == host then
          last = r.path
          break
        end
      end
      root = ask_folder(conn, last or conn.home)
    end
    if not root then
      return
    end
    M.workspaces[host] = root
    M.current = { host = host, root = root }
    state.add_recent(host, root)
    mod("tree").open(host, root)
    mod("log").info(("Opened %s on '%s'."):format(root, host))
  end)
end

--- Pick from recently opened workspaces.
function M.recent()
  local list = mod("state").recent()
  if #list == 0 then
    return mod("log").info("No recent remote workspaces yet. Use :RemoteSSH open")
  end
  if has_telescope() then
    return mod("telescope").recent()
  end
  vim.ui.select(list, {
    prompt = "Recent remote workspaces",
    format_item = function(r)
      return r.host .. ":" .. r.path
    end,
  }, function(r)
    if r then
      M.open(r.host, r.path)
    end
  end)
end

function M.disconnect(host)
  host = host and host ~= "" and host or (M.context())
  local conn = host and mod("connection").get(host)
  if not conn then
    return mod("log").warn("Not connected.")
  end
  conn:close(function()
    mod("log").info(("Disconnected from '%s'."):format(host))
  end)
end

function M.reconnect(host)
  host = host and host ~= "" and host or (M.context())
  if not host then
    return mod("log").warn("No host to reconnect to. Use :RemoteSSH connect")
  end
  local conn = mod("connection").get(host)
  if conn then
    conn.attempts = 0
  end
  M.connect(host)
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

local function edit_remote(host, path, lnum, col, cmd)
  vim.cmd((cmd or "edit") .. " " .. vim.fn.fnameescape(mod("path").uri(host, path)))
  if lnum then
    pcall(api.nvim_win_set_cursor, 0, { lnum, math.max((col or 1) - 1, 0) })
    vim.cmd("normal! zz")
  end
end
M.edit = edit_remote

--- Find a file in the workspace.
function M.files()
  local conn, root = need_context()
  if not conn then
    return
  end
  if has_telescope() then
    return mod("telescope").files({ conn = conn, root = root })
  end
  mod("search").files(conn, root, function(err, files, truncated)
    if err then
      return mod("log").error("File search failed: " .. (err.message or err.code))
    end
    vim.ui.select(files, { prompt = ("Files in %s%s"):format(root, truncated and " (list truncated)" or "") }, function(choice)
      if choice then
        edit_remote(conn.host, mod("path").join(root, choice))
      end
    end)
  end)
end

--- Search text in the workspace. With telescope this is a live search;
--- without it (or with a pattern given) results go to the quickfix list.
function M.grep(pattern)
  local conn, root = need_context()
  if not conn then
    return
  end
  if (not pattern or pattern == "") and has_telescope() then
    return mod("telescope").live_grep({ conn = conn, root = root })
  end
  if not pattern or pattern == "" then
    pattern = mod("ui").input("Search for: ", "")
    if not pattern or pattern == "" then
      return
    end
  end
  mod("search").grep_to_quickfix(conn, root, pattern, function(info, items)
    if info.error then
      return mod("log").error("Search failed: " .. info.error)
    end
    if #items == 0 then
      return mod("log").info("No matches for " .. pattern)
    end
    if info.truncated then
      mod("log").warn(("Showing the first %d matches."):format(#items))
    end
    vim.cmd("botright copen")
  end)
end

--- Functions, methods, classes of the current buffer.
function M.symbols()
  local buf = api.nvim_get_current_buf()
  local list, why = mod("symbols").any(buf)
  if not list then
    return mod("log").warn("No symbols: " .. why .. ".")
  end
  if #list == 0 then
    return mod("log").info("No symbols found in this buffer.")
  end
  if has_telescope() then
    return mod("telescope").symbols({ bufnr = buf, symbols = list })
  end
  vim.ui.select(list, {
    prompt = "Symbols",
    format_item = function(s)
      return ("%s%s  [%s]  :%d"):format(string.rep("  ", s.depth), s.name, s.kind, s.lnum)
    end,
  }, function(s)
    if s then
      api.nvim_win_set_cursor(0, { s.lnum, s.col - 1 })
      vim.cmd("normal! zz")
    end
  end)
end

function M.outline()
  mod("symbols").outline()
end

function M.tree()
  local host, root = M.context()
  if not host then
    return mod("log").warn("No remote workspace is open. Use :RemoteSSH open")
  end
  mod("tree").toggle(host, root)
end

function M.terminal()
  local conn, root = need_context()
  if conn then
    mod("terminal").open(conn.host, root)
  end
end

--- forward("8080") / forward("8080:3000") / forward("8080:dbhost:5432")
function M.forward(spec)
  local conn = need_context()
  if not conn then
    return
  end
  if not spec or spec == "" then
    local list = mod("forward").list(conn)
    return mod("log").info(#list == 0 and "No ports are forwarded." or ("Forwarded ports (local:host:remote):\n  " .. table.concat(list, "\n  ")))
  end
  mod("forward").add(conn, spec)
end

function M.unforward(spec)
  local conn = need_context()
  if conn and spec and spec ~= "" then
    mod("forward").remove(conn, spec)
  end
end

-- ---------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------

function M.info()
  local lines = {}
  for host, conn in pairs(mod("connection").conns) do
    lines[#lines + 1] = ("%s: %s%s"):format(host, conn.state, conn.status and (" (" .. conn.status .. ")") or "")
    if conn.state == "connected" then
      local i = conn.info or {}
      lines[#lines + 1] = ("  system: %s %s, %s"):format(i.os or "?", i.arch or "?", i.libc or "?")
      lines[#lines + 1] = ("  agent: nvim %s in %s"):format(conn.agent.nvim, conn.agent.base)
      lines[#lines + 1] = ("  workspace: %s"):format(M.workspaces[host] or "(none)")
      lines[#lines + 1] = ("  search: %s, language server installer: %s"):format(i.rg ~= "none" and "ripgrep" or "grep/find", conn.agent.mason and "mason" or "unavailable")
      local fw = mod("forward").list(conn)
      if #fw > 0 then
        lines[#lines + 1] = "  forwards: " .. table.concat(fw, ", ")
      end
    elseif conn.last_error then
      lines[#lines + 1] = "  last error: " .. mod("util").errmsg(conn.last_error):gsub("\n", "\n    ")
    end
  end
  if #lines == 0 then
    lines = { "No remote connections. Use :RemoteSSH connect" }
  end
  api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
end

--- Retry optional components (ripgrep, mason) that failed to install.
function M.setup_host(host)
  host = host and host ~= "" and host or (M.context())
  if not host then
    return mod("log").warn("Usage: :RemoteSSH setup <host>")
  end
  local state = mod("state")
  state.host(host).skip = nil
  state.save()
  local conn = mod("connection").get(host)
  local function go()
    M.connect(host)
  end
  if conn and conn.state == "connected" then
    conn:close(function()
      vim.defer_fn(go, 600)
    end)
  else
    go()
  end
end

--- Remove everything remote-ssh installed on a host.
function M.uninstall(host)
  host = host and host ~= "" and host or (M.context())
  if not host then
    return mod("log").warn("Usage: :RemoteSSH uninstall <host>")
  end
  local log, ssh, util, state = mod("log"), mod("ssh"), mod("util"), mod("state")
  M.connect(host, function(err, conn)
    if err then
      return
    end
    local base = conn.agent.base
    if not base:match("/nvim%-remote%-ssh$") then
      return log.error(("Refusing to delete %s: it is not a remote-ssh directory."):format(base))
    end
    if mod("ui").confirm(("Delete everything remote-ssh installed on '%s'?\n  %s\nLanguage servers installed there are removed too."):format(host, base), { "Delete", "Cancel" }) ~= 1 then
      return
    end
    conn.user_closed = true
    if conn.session then
      conn.session:notify("shutdown", {})
    end
    vim.defer_fn(function()
      ssh.script(host, "rm -rf " .. util.shq(base) .. " && echo RSSH_REMOVED", { timeout = 120000 }, function(res)
        if res.body and res.body:find("RSSH_REMOVED", 1, true) then
          state.load().hosts[host] = nil
          state.save()
          log.info(("Removed %s from '%s'."):format(base, host))
        else
          log.error(("Could not remove %s on '%s': %s"):format(base, host, util.tail(res.stderr, 3)))
        end
        ssh.control(host, "exit", nil, function() end)
      end)
    end, 500)
  end)
end

--- For statuslines: "" when nothing remote is going on.
function M.statusline()
  local host = M.context()
  local conn = host and mod("connection").get(host)
  if not conn then
    return ""
  end
  if conn.state == "connected" then
    return "SSH: " .. host
  elseif conn.state == "connecting" then
    return ("SSH: %s (%s...)"):format(host, (conn.status or "connecting"):lower())
  end
  return ("SSH: %s (disconnected)"):format(host)
end

return M
