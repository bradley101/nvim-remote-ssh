-- rssh:// buffers: reading, writing with conflict detection, reloading when
-- the file changes on the server.
local api = vim.api
local P = require("remote-ssh.path")
local connection = require("remote-ssh.connection")
local config = require("remote-ssh.config")
local ui = require("remote-ssh.ui")
local log = require("remote-ssh.log")
local util = require("remote-ssh.util")

local M = {}

--- Per-buffer metadata: host, path, mtime_sec, mtime_nsec, size, new, failed.
M.meta = {}

local function denil(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

local function get_conn(host)
  local conn = connection.get(host)
  if conn and conn.state == "connected" then
    return conn
  end
  return connection.connect_sync(host)
end

local function set_lines(bufnr, lines, keep_undo)
  vim.bo[bufnr].modifiable = true
  if keep_undo then
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    local ul = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].undolevels = ul
  end
end

--- Split file contents into buffer lines; returns lines, fileformat, eol.
function M.decode(data)
  local lines = vim.split(data, "\n", { plain = true })
  local eol = true
  if lines[#lines] == "" then
    lines[#lines] = nil
  else
    eol = false
  end
  local ff = "unix"
  if #lines > 0 then
    local dos = true
    local last = #lines
    for i, l in ipairs(lines) do
      -- The last line of a file without a trailing newline has no CR.
      if l:sub(-1) ~= "\r" and not (i == last and not eol) then
        dos = false
        break
      end
    end
    if dos and not (last == 1 and not eol) then
      ff = "dos"
      for i, l in ipairs(lines) do
        if l:sub(-1) == "\r" then
          lines[i] = l:sub(1, -2)
        end
      end
    end
  end
  return lines, ff, eol
end

--- Inverse of decode.
function M.encode(lines, ff, eol)
  if #lines == 0 then
    return ""
  end
  local sep = ff == "dos" and "\r\n" or "\n"
  local data = table.concat(lines, sep)
  if eol then
    data = data .. sep
  end
  return data
end

local function mark_failed(bufnr, host, path, message)
  M.meta[bufnr] = { host = host, path = path, failed = true }
  set_lines(bufnr, {})
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
  log.error(message)
end

--- Load (or reload) the remote file behind bufnr.
function M.read(bufnr, opts)
  opts = opts or {}
  local name = api.nvim_buf_get_name(bufnr)
  local host, path = P.parse(name)
  if not host then
    return log.error("Not a remote file name: " .. name)
  end
  local canon = P.uri(host, path)
  if canon ~= name then
    pcall(api.nvim_buf_set_name, bufnr, canon)
  end

  local conn, cerr = get_conn(host)
  if not conn then
    return mark_failed(bufnr, host, path, ("Cannot open %s: %s"):format(canon, cerr and cerr.kind == "cancelled" and "connection cancelled" or "not connected"))
  end

  local limit = config.get().files.max_size
  local res, err = conn:call("fs.read", { path = path, max_size = limit })
  if err and err.code == "ETOOBIG" then
    local mb = (err.size or 0) / 1048576
    if ui.confirm(("%s is %.0f MB. Open it anyway?"):format(path, mb), { "Open", "Cancel" }) == 1 then
      res, err = conn:call("fs.read", { path = path }, 300000)
    else
      return mark_failed(bufnr, host, path, "Not opened: file too large.")
    end
  end

  if err then
    if err.code == "ENOENT" then
      M.meta[bufnr] = { host = host, path = path, new = true }
      set_lines(bufnr, {})
      vim.bo[bufnr].buftype = "acwrite"
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].modified = false
      api.nvim_echo({ { ('"%s" [New]'):format(canon) } }, false, {})
      api.nvim_buf_call(bufnr, function()
        pcall(api.nvim_exec_autocmds, "BufNewFile", { buffer = bufnr })
      end)
      M.detect_filetype(bufnr, path)
      return
    elseif err.code == "EISDIR" then
      M.meta[bufnr] = nil
      vim.schedule(function()
        if api.nvim_buf_is_valid(bufnr) then
          pcall(api.nvim_buf_delete, bufnr, { force = true })
        end
        require("remote-ssh.tree").open(host, path)
      end)
      return
    end
    return mark_failed(bufnr, host, path, ("Cannot open %s: %s"):format(canon, err.message or err.code))
  end

  local lines, ff, eol = M.decode(res.data)
  local cursors = {}
  if opts.reload then
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      cursors[win] = api.nvim_win_get_cursor(win)
    end
  end
  set_lines(bufnr, lines, opts.reload)
  for win, cur in pairs(cursors) do
    cur[1] = math.max(1, math.min(cur[1], api.nvim_buf_line_count(bufnr)))
    pcall(api.nvim_win_set_cursor, win, cur)
  end
  vim.bo[bufnr].fileformat = ff
  vim.bo[bufnr].endofline = eol
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].readonly = not res.writable
  vim.bo[bufnr].modified = false
  M.meta[bufnr] = {
    host = host,
    path = path,
    mtime_sec = res.stat.mtime_sec,
    mtime_nsec = res.stat.mtime_nsec,
    size = res.stat.size,
  }
  if config.get().files.watch then
    conn:notify("fs.watch", { path = path })
  end
  if not opts.reload then
    api.nvim_buf_call(bufnr, function()
      pcall(api.nvim_exec_autocmds, "BufReadPost", { buffer = bufnr })
    end)
    M.detect_filetype(bufnr, path)
  end
end

function M.detect_filetype(bufnr, path)
  if vim.bo[bufnr].filetype ~= "" then
    return
  end
  local ok, ft = pcall(vim.filetype.match, { buf = bufnr, filename = path })
  if ok and ft then
    vim.bo[bufnr].filetype = ft
  end
end

--- Save bufnr to `target` (a rssh:// name; normally the buffer's own).
function M.write(bufnr, target)
  local host, path = P.parse(target)
  if not host then
    return log.error("Not a remote file name: " .. target)
  end
  local meta = M.meta[bufnr] or {}
  local own = meta.host == host and meta.path == path
  if own and meta.failed then
    return log.error(("Not saving %s: this buffer never loaded the file's contents (reopen it with :edit)."):format(target))
  end

  local conn = connection.get(host)
  if not conn or conn.state ~= "connected" then
    log.error(("Not connected to '%s': %s was NOT saved. Your changes are kept in the buffer; save again once reconnected."):format(host, path))
    if not conn or conn.state == "disconnected" then
      connection.connect(host, {})
    end
    return
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local eol = vim.bo[bufnr].endofline or (vim.bo[bufnr].fixendofline and not vim.bo[bufnr].binary)
  local data
  if #lines == 1 and lines[1] == "" and (meta.size == 0 or meta.new) then
    data = "" -- an empty file stays empty
  else
    data = M.encode(lines, vim.bo[bufnr].fileformat, eol)
  end

  local params = { path = path, data = data, mkdir = true }
  if vim.v.cmdbang == 1 then
    params.force = true
  elseif own and meta.mtime_sec then
    params.expect_mtime_sec, params.expect_mtime_nsec = meta.mtime_sec, meta.mtime_nsec
  else
    params.expect_absent = true
  end

  local res, err = conn:call("fs.write", params, 120000)
  if err and err.code == "ECONFLICT" then
    local choice = ui.confirm(
      ("%s:\n  %s\n\nYour buffer has changes based on the older version."):format(err.message:gsub("^%l", string.upper), target),
      { "Overwrite", "Reload (discard my changes)", "Cancel" }
    )
    if choice == 1 then
      params.force = true
      res, err = conn:call("fs.write", params, 120000)
    elseif choice == 2 then
      return M.read(bufnr, { reload = true })
    else
      return log.warn(("%s was not saved."):format(path))
    end
  elseif err and err.code == "EEXIST" then
    if ui.confirm(("%s already exists on '%s'. Overwrite it?"):format(path, host), { "Overwrite", "Cancel" }) == 1 then
      params.force = true
      res, err = conn:call("fs.write", params, 120000)
    else
      return log.warn(("%s was not saved."):format(path))
    end
  end
  if err then
    local why = err.message or err.code
    if err.code == "EACCES" or err.code == "EPERM" then
      why = "permission denied"
    elseif err.code == "ENOSPC" then
      why = "no space left on the server"
    elseif err.code == "ECLOSED" or err.code == "ETIMEDOUT" then
      why = "connection lost; your changes are kept in the buffer"
    end
    return log.error(("Could not save %s: %s"):format(target, why))
  end

  if api.nvim_buf_get_name(bufnr) == P.uri(host, path) then
    M.meta[bufnr] = {
      host = host,
      path = path,
      mtime_sec = res.stat.mtime_sec,
      mtime_nsec = res.stat.mtime_nsec,
      size = res.stat.size,
    }
    vim.bo[bufnr].modified = false
    if config.get().files.watch then
      conn:notify("fs.watch", { path = path })
    end
  end
  api.nvim_echo({ { ('"%s" %dL, %dB written'):format(target, #lines, #data) } }, false, {})
  api.nvim_buf_call(bufnr, function()
    pcall(api.nvim_exec_autocmds, "BufWritePost", { buffer = bufnr })
  end)
  return true
end

local function find_buf(host, path)
  for bufnr, meta in pairs(M.meta) do
    if meta.host == host and meta.path == path and api.nvim_buf_is_valid(bufnr) then
      return bufnr, meta
    end
  end
end

local function on_changed(conn, params)
  local bufnr, meta = find_buf(conn.host, params.path)
  if not bufnr or meta.failed then
    return
  end
  local stat = denil(params.stat)
  if not stat then
    if not meta.warned_deleted then
      meta.warned_deleted = true
      log.warn(("%s was deleted on '%s'. The buffer keeps its contents."):format(params.path, conn.host))
    end
    return
  end
  meta.warned_deleted = nil
  if stat.mtime_sec == meta.mtime_sec and stat.mtime_nsec == meta.mtime_nsec then
    return -- our own write
  end
  if vim.bo[bufnr].modified then
    local stamp = stat.mtime_sec .. "." .. stat.mtime_nsec
    if meta.warned_stale ~= stamp then
      meta.warned_stale = stamp
      log.warn(("%s changed on '%s' while you have unsaved edits. Saving will ask what to do."):format(params.path, conn.host))
    end
    return
  end
  M.read(bufnr, { reload = true })
end

function M.setup()
  local group = api.nvim_create_augroup("RemoteSSHBuffers", { clear = true })
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "rssh://*",
    nested = true,
    callback = function(args)
      M.read(args.buf)
    end,
  })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "rssh://*",
    nested = true,
    callback = function(args)
      M.write(args.buf, args.match)
    end,
  })
  api.nvim_create_autocmd("FileReadCmd", {
    group = group,
    pattern = "rssh://*",
    callback = function(args)
      local host, path = P.parse(args.match)
      local conn = host and get_conn(host)
      if not conn then
        return log.error("Not connected: " .. args.match)
      end
      local res, err = conn:call("fs.read", { path = path, max_size = config.get().files.max_size })
      if err then
        return log.error(("Cannot read %s: %s"):format(args.match, err.message or err.code))
      end
      local lines = M.decode(res.data)
      api.nvim_buf_set_lines(args.buf, vim.fn.line("'["), vim.fn.line("'["), false, lines)
    end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    pattern = "rssh://*",
    callback = function(args)
      local meta = M.meta[args.buf]
      M.meta[args.buf] = nil
      if meta and not meta.failed then
        local conn = connection.get(meta.host)
        if conn then
          conn:notify("fs.unwatch", { path = meta.path })
        end
      end
    end,
  })

  connection.on("connected", function(conn)
    if not conn.buffer_events then
      conn.buffer_events = true
      conn:on("fs.changed", function(params)
        on_changed(conn, params)
      end)
    end
    -- After a reconnect: watch again, and load buffers that failed earlier.
    for bufnr, meta in pairs(M.meta) do
      if meta.host == conn.host and api.nvim_buf_is_valid(bufnr) then
        if meta.failed then
          if not vim.bo[bufnr].modified then
            M.read(bufnr)
          end
        elseif not meta.new and config.get().files.watch then
          conn:notify("fs.watch", { path = meta.path })
        end
      end
    end
  end)
end

M._util = util
return M
