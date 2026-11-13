-- Makes telescope's own find_files / live_grep / grep_string search the
-- remote workspace when one is in use, so existing key mappings (for example
-- <leader>ff, <leader>fw) keep working. Without this they run ripgrep on the
-- local machine, in the directory Neovim was started from.
local api = vim.api

local M = {}

local installed = false

--- Where a search started from the current window should run:
--- conn, root  -> on that remote workspace
--- false       -> remote, but not connected (the user has been told)
--- nil         -> locally, as usual
function M.target()
  local rs = require("remote-ssh")
  local buf = api.nvim_get_current_buf()
  local host, root
  local meta = require("remote-ssh.buffer").meta[buf]
  local tree = require("remote-ssh.tree").trees[buf]
  if meta then
    host, root = meta.host, rs.workspaces[meta.host] or require("remote-ssh.path").dirname(meta.path)
  elseif tree then
    host, root = tree.host, rs.workspaces[tree.host] or tree.root
  elseif rs.current then
    -- A local file is being edited: search locally. Anything else (empty
    -- buffer, dashboard, terminal...) belongs to the open remote workspace.
    if vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= "" then
      return nil
    end
    host, root = rs.current.host, rs.current.root
  else
    return nil
  end
  local conn = require("remote-ssh.connection").get(host)
  if not conn or conn.state ~= "connected" then
    require("remote-ssh.log").warn(("Not connected to '%s'. Use :RemoteSSH reconnect"):format(host))
    return false
  end
  return conn, root
end

--- An explicit directory means the caller wants that (local) place.
local function explicit_local(opts)
  return opts.cwd ~= nil or opts.search_dirs ~= nil or opts.rssh_local == true
end

local remote = {}

function remote.find_files(opts, conn, root)
  opts.conn, opts.root = conn, root
  require("remote-ssh.telescope").files(opts)
end

function remote.live_grep(opts, conn, root)
  opts.conn, opts.root = conn, root
  require("remote-ssh.telescope").live_grep(opts)
end

function remote.grep_string(opts, conn, root)
  opts.conn, opts.root = conn, root
  opts.default_text = opts.search or vim.fn.expand("<cword>")
  opts.search = nil
  require("remote-ssh.telescope").live_grep(opts)
end

local function wrap(name, original)
  return function(opts, ...)
    opts = opts or {}
    if type(opts) == "table" and not explicit_local(opts) then
      local conn, root = M.target()
      if conn == false then
        return
      end
      if conn then
        return remote[name](opts, conn, root)
      end
    end
    return original(opts, ...)
  end
end

--- Install the overrides (once). Safe to call when telescope is missing.
function M.install()
  if installed or not require("remote-ssh.config").get().telescope.override_builtins then
    return
  end
  local ok_b, builtin = pcall(require, "telescope.builtin")
  if not ok_b or type(builtin) ~= "table" then
    return
  end
  installed = true
  -- telescope.builtin entries call through to this module at call time, so
  -- wrapping here also covers mappings that captured builtin.find_files
  -- before we were loaded.
  local ok_f, files = pcall(require, "telescope.builtin.__files")
  for name in pairs(remote) do
    if ok_f and type(files) == "table" and type(files[name]) == "function" then
      files[name] = wrap(name, files[name])
    end
    if type(builtin[name]) == "function" then
      builtin[name] = wrap(name, builtin[name])
    end
  end
end

return M
