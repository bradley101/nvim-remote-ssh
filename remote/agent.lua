-- remote-ssh agent. Runs ON THE SERVER under a headless Neovim:
--
--   nvim -u NONE -i NONE -n -l agent.lua <base_dir> 3>&1 1>&2
--
-- It speaks a small length-prefixed msgpack protocol on stdin / fd 3 (fd 1 is
-- redirected to stderr so stray print() output can never corrupt the stream).
-- Frame: 4-byte big-endian length + msgpack array:
--   request      {0, id, method, params}
--   response     {1, id, err, result}
--   notification {2, method, params}
-- The agent only ever answers requests and emits notifications; it has no way
-- to call into the client.
local uv = vim.uv or vim.loop
local mpack = vim.mpack
local NIL = vim.NIL

local AGENT_VERSION = 1
local base = (arg and arg[1]) or (uv.os_homedir() .. "/.local/share/nvim-remote-ssh")

-- Tools installed by the plugin take part in PATH for everything we spawn.
do
  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin"
  uv.os_setenv("PATH", base .. "/bin:" .. base .. "/mason/bin:" .. path)
end

local function opt(v)
  if v == NIL then
    return nil
  end
  return v
end

local function fail(code, message)
  return { code = code, message = message }
end

--- Convert a luv error string ("ENOENT: no such file or directory: /x") into
--- our error shape.
local function uverr(e)
  e = tostring(e)
  local code, msg = e:match("^(%u+): (.*)$")
  return fail(code or "EIO", msg or e)
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------
local out = uv.new_pipe(false)
out:open(3)
local inp = uv.new_pipe(false)
inp:open(0)

local function send(msg)
  local payload = mpack.encode(msg)
  local n = #payload
  local header = string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
  out:write(header .. payload)
end

local function notify(method, params)
  send({ 2, method, params })
end

local handlers = {}
local procs = {}
local quitting = false

local function shutdown()
  if quitting then
    return
  end
  quitting = true
  for _, p in pairs(procs) do
    pcall(uv.kill, p.pid, "sigterm")
  end
  os.exit(0)
end

local function dispatch(msg)
  local kind = msg[1]
  if kind == 0 then
    local id, method, params = msg[2], msg[3], msg[4]
    local replied = false
    local function respond(err, result)
      if replied then
        return
      end
      replied = true
      send({ 1, id, err or NIL, result == nil and NIL or result })
    end
    local h = handlers[method]
    if not h then
      return respond(fail("ENOMETHOD", "unknown method " .. tostring(method)))
    end
    local ok, e = pcall(h, type(params) == "table" and params or {}, respond)
    if not ok then
      respond(fail("EAGENT", tostring(e)))
    end
  elseif kind == 2 then
    local h = handlers[msg[2]]
    if h then
      pcall(h, type(msg[3]) == "table" and msg[3] or {}, function() end)
    end
  end
end

do
  local chunks, size, need = {}, 0, nil
  inp:read_start(function(err, data)
    if err or not data then
      return vim.schedule(shutdown)
    end
    chunks[#chunks + 1] = data
    size = size + #data
    while true do
      if not need then
        if size < 4 then
          break
        end
        local s = table.concat(chunks)
        chunks = { s }
        local a, b, c, d = s:byte(1, 4)
        need = ((a * 256 + b) * 256 + c) * 256 + d
      end
      if size < 4 + need then
        break
      end
      local s = table.concat(chunks)
      local frame = s:sub(5, 4 + need)
      local rest = s:sub(5 + need)
      chunks, size, need = { rest }, #rest, nil
      local ok, msg = pcall(mpack.decode, frame)
      if ok and type(msg) == "table" then
        vim.schedule(function()
          dispatch(msg)
        end)
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Filesystem
-- ---------------------------------------------------------------------------
local function dirname(p)
  local d = p:match("^(.*)/[^/]*$")
  if d == nil then
    return "."
  end
  return d == "" and "/" or d
end

local function basename(p)
  return p:match("([^/]*)$")
end

local function pack_stat(st)
  if not st then
    return nil
  end
  return {
    type = st.type,
    size = st.size,
    mode = st.mode,
    mtime_sec = st.mtime.sec,
    mtime_nsec = st.mtime.nsec,
  }
end

local function mkdir_p(path)
  local st = uv.fs_stat(path)
  if st then
    if st.type == "directory" then
      return true
    end
    return nil, "ENOTDIR: not a directory: " .. path
  end
  local parent = dirname(path)
  if parent ~= path then
    local ok, e = mkdir_p(parent)
    if not ok then
      return nil, e
    end
  end
  local ok, e = uv.fs_mkdir(path, 493) -- 0755
  if not ok and not uv.fs_stat(path) then
    return nil, e
  end
  return true
end

local function write_all(fd, data)
  local off = 0
  while off < #data do
    local n, e = uv.fs_write(fd, off == 0 and data or data:sub(off + 1), off)
    if not n then
      return nil, e
    end
    if n == 0 then
      return nil, "EIO: short write"
    end
    off = off + n
  end
  return true
end

handlers["ping"] = function(_, respond)
  local v = vim.version()
  respond(nil, {
    agent = AGENT_VERSION,
    nvim = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
    home = uv.os_homedir(),
    pid = uv.os_getpid(),
    base = base,
    sysname = uv.os_uname().sysname,
    mason = uv.fs_stat(base .. "/plugins/mason.nvim/lua/mason/init.lua") ~= nil,
  })
end

handlers["fs.stat"] = function(p, respond)
  local st = uv.fs_stat(p.path)
  respond(nil, { stat = pack_stat(st) or NIL, realpath = uv.fs_realpath(p.path) or NIL })
end

handlers["fs.read"] = function(p, respond)
  local st, e = uv.fs_stat(p.path)
  if not st then
    return respond(uverr(e))
  end
  if st.type == "directory" then
    return respond(fail("EISDIR", "is a directory: " .. p.path))
  end
  if st.type ~= "file" then
    return respond(fail("ENOTFILE", ("not a regular file (%s): %s"):format(st.type, p.path)))
  end
  local limit = opt(p.max_size)
  if limit and st.size > limit then
    local err = fail("ETOOBIG", ("file is %d bytes (limit %d)"):format(st.size, limit))
    err.size = st.size
    return respond(err)
  end
  local fd, oe = uv.fs_open(p.path, "r", 0)
  if not fd then
    return respond(uverr(oe))
  end
  local parts, off = {}, 0
  while true do
    local chunk, re = uv.fs_read(fd, 1048576, off)
    if not chunk then
      uv.fs_close(fd)
      return respond(uverr(re))
    end
    if #chunk == 0 then
      break
    end
    parts[#parts + 1] = chunk
    off = off + #chunk
  end
  -- Re-stat through the descriptor so the mtime matches what we read.
  local fst = uv.fs_fstat(fd) or st
  uv.fs_close(fd)
  local access = uv.fs_access(p.path, "W")
  respond(nil, { data = table.concat(parts), stat = pack_stat(fst), writable = access and true or false })
end

handlers["fs.write"] = function(p, respond)
  local path = uv.fs_realpath(p.path) or p.path -- write through symlinks
  local st = uv.fs_stat(path)
  if st and st.type == "directory" then
    return respond(fail("EISDIR", "is a directory: " .. path))
  end
  if not opt(p.force) then
    local want_sec = opt(p.expect_mtime_sec)
    if want_sec then
      if not st then
        return respond(fail("ECONFLICT", "the file was deleted on the server"))
      end
      if st.mtime.sec ~= want_sec or st.mtime.nsec ~= (opt(p.expect_mtime_nsec) or 0) then
        return respond(fail("ECONFLICT", "the file was changed on the server"))
      end
    elseif opt(p.expect_absent) and st then
      return respond(fail("EEXIST", "file already exists: " .. path))
    end
  end
  local dir = dirname(path)
  if opt(p.mkdir) then
    local ok, e = mkdir_p(dir)
    if not ok then
      return respond(uverr(e))
    end
  end

  local data = p.data or ""
  local mode = st and (st.mode % 4096) or 420 -- keep permissions; 0644 for new files
  -- Atomic replace (temp file + rename) unless that would change ownership
  -- or break hard links.
  local atomic = not st or (st.nlink == 1 and st.uid == uv.getuid())
  local tmp, fd, e
  if atomic then
    tmp = ("%s/.%s.rssh-%d.tmp"):format(dir, basename(path), uv.os_getpid())
    fd = uv.fs_open(tmp, "wx", mode)
  end
  if fd then
    local ok
    ok, e = write_all(fd, data)
    if ok then
      uv.fs_fsync(fd)
    end
    uv.fs_close(fd)
    if ok then
      uv.fs_chmod(tmp, mode)
      ok, e = uv.fs_rename(tmp, path)
    end
    if not ok then
      uv.fs_unlink(tmp)
      return respond(uverr(e))
    end
  else
    fd, e = uv.fs_open(path, "w", mode)
    if not fd then
      return respond(uverr(e))
    end
    local ok
    ok, e = write_all(fd, data)
    uv.fs_close(fd)
    if not ok then
      return respond(uverr(e))
    end
  end
  respond(nil, { stat = pack_stat(uv.fs_stat(path)), realpath = path })
end

handlers["fs.list"] = function(p, respond)
  local req, e = uv.fs_scandir(p.path)
  if not req then
    return respond(uverr(e))
  end
  local entries = {}
  while true do
    local name, t = uv.fs_scandir_next(req)
    if not name then
      break
    end
    local entry = { name = name, type = t or "unknown" }
    if t == "link" or t == nil or t == "unknown" then
      local st = uv.fs_stat(p.path .. "/" .. name)
      entry.link = t == "link"
      entry.type = st and st.type or (t == "link" and "broken" or "unknown")
    end
    entries[#entries + 1] = entry
  end
  table.sort(entries, function(a, b)
    local da, db = a.type == "directory", b.type == "directory"
    if da ~= db then
      return da
    end
    local la, lb = a.name:lower(), b.name:lower()
    if la == lb then
      return a.name < b.name
    end
    return la < lb
  end)
  respond(nil, { entries = entries })
end

handlers["fs.mkdir"] = function(p, respond)
  if uv.fs_stat(p.path) then
    return respond(fail("EEXIST", "already exists: " .. p.path))
  end
  local ok, e = mkdir_p(p.path)
  if not ok then
    return respond(uverr(e))
  end
  respond(nil, true)
end

handlers["fs.rename"] = function(p, respond)
  if uv.fs_lstat(p.to) and not opt(p.force) then
    return respond(fail("EEXIST", "already exists: " .. p.to))
  end
  local ok, e = mkdir_p(dirname(p.to))
  if ok then
    ok, e = uv.fs_rename(p.from, p.to)
  end
  if not ok then
    return respond(uverr(e))
  end
  respond(nil, true)
end

local function remove_tree(path)
  local st, e = uv.fs_lstat(path)
  if not st then
    return nil, e
  end
  if st.type == "directory" then
    local req, se = uv.fs_scandir(path)
    if not req then
      return nil, se
    end
    while true do
      local name = uv.fs_scandir_next(req)
      if not name then
        break
      end
      local ok, re = remove_tree(path .. "/" .. name)
      if not ok then
        return nil, re
      end
    end
    return uv.fs_rmdir(path)
  end
  return uv.fs_unlink(path)
end

handlers["fs.remove"] = function(p, respond)
  local path = p.path
  local clean = path:gsub("/+$", "")
  if clean == "" or clean == uv.os_homedir() then
    return respond(fail("EPERM", "refusing to delete " .. path))
  end
  local st, e = uv.fs_lstat(path)
  if not st then
    return respond(uverr(e))
  end
  local ok
  if st.type == "directory" and not opt(p.recursive) then
    ok, e = uv.fs_rmdir(path)
  else
    ok, e = remove_tree(path)
  end
  if not ok then
    return respond(uverr(e))
  end
  respond(nil, true)
end

local function copy_tree(from, to)
  local st, e = uv.fs_lstat(from)
  if not st then
    return nil, e
  end
  if st.type == "directory" then
    local ok, me = uv.fs_mkdir(to, st.mode % 4096)
    if not ok then
      return nil, me
    end
    local req, se = uv.fs_scandir(from)
    if not req then
      return nil, se
    end
    while true do
      local name = uv.fs_scandir_next(req)
      if not name then
        break
      end
      local cok, ce = copy_tree(from .. "/" .. name, to .. "/" .. name)
      if not cok then
        return nil, ce
      end
    end
    return true
  elseif st.type == "link" then
    local target, le = uv.fs_readlink(from)
    if not target then
      return nil, le
    end
    return uv.fs_symlink(target, to)
  end
  return uv.fs_copyfile(from, to, { excl = true })
end

handlers["fs.copy"] = function(p, respond)
  if uv.fs_lstat(p.to) then
    return respond(fail("EEXIST", "already exists: " .. p.to))
  end
  local ok, e = copy_tree(p.from, p.to)
  if not ok then
    return respond(uverr(e))
  end
  respond(nil, true)
end

--- Walk upwards from `path` looking for marker files. `groups` is a list of
--- lists of names; earlier groups take priority.
handlers["fs.find_root"] = function(p, respond)
  local start = p.path
  local st = uv.fs_stat(start)
  if st and st.type ~= "directory" then
    start = dirname(start)
  elseif not st then
    start = dirname(start)
  end
  for _, group in ipairs(p.groups or {}) do
    local dir = start
    while true do
      for _, name in ipairs(group) do
        if uv.fs_stat(dir .. "/" .. name) then
          return respond(nil, { root = dir, marker = name })
        end
      end
      local parent = dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
  end
  respond(nil, { root = NIL })
end

-- File watching: polling stat is slower than inotify but survives the
-- rename-into-place that most editors and tools use when saving.
local watches = {}

handlers["fs.watch"] = function(p, respond)
  local path = p.path
  if not watches[path] then
    local w = uv.new_fs_poll()
    watches[path] = w
    w:start(path, opt(p.interval) or 2000, function(err, _, cur)
      if err then
        notify("fs.changed", { path = path, stat = NIL })
      else
        notify("fs.changed", { path = path, stat = pack_stat(cur) or NIL })
      end
    end)
  end
  respond(nil, true)
end

handlers["fs.unwatch"] = function(p, respond)
  local w = watches[p.path]
  if w then
    w:stop()
    w:close()
    watches[p.path] = nil
  end
  respond(nil, true)
end

-- ---------------------------------------------------------------------------
-- Processes
-- ---------------------------------------------------------------------------
local function child_env(extra)
  local env = uv.os_environ()
  env.NVIM_APPNAME = nil -- ours, not for children
  env.NVIM = nil
  env.VIMRUNTIME = nil
  env.VIM = nil
  for k, v in pairs(extra or {}) do
    if v == NIL then
      env[k] = nil
    else
      env[k] = tostring(v)
    end
  end
  local list = {}
  for k, v in pairs(env) do
    list[#list + 1] = k .. "=" .. v
  end
  return list
end

--- Spawn with pipes. cbs: stdout(chunk), stderr(chunk), exit(code, signal).
local function spawn(cmd, cwd, env, cbs)
  if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
    return nil, fail("EINVAL", "cmd must be a list of strings")
  end
  if cwd then
    local st = uv.fs_stat(cwd)
    if not st or st.type ~= "directory" then
      return nil, fail("ENOENT", "working directory does not exist: " .. cwd)
    end
  end
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local p = {}
  local streams = 2
  local code, signal
  local function maybe_done()
    if p.exited and streams == 0 then
      for _, s in ipairs({ stdin, stdout, stderr }) do
        if not s:is_closing() then
          s:close()
        end
      end
      cbs.exit(code, signal)
    end
  end
  local args = {}
  for i = 2, #cmd do
    args[#args + 1] = tostring(cmd[i])
  end
  local handle, pid = uv.spawn(cmd[1], {
    args = args,
    stdio = { stdin, stdout, stderr },
    cwd = cwd,
    env = child_env(env),
  }, function(c, s)
    code, signal = c, s
    p.exited = true
    if p.handle and not p.handle:is_closing() then
      p.handle:close()
    end
    maybe_done()
  end)
  if not handle then
    for _, s in ipairs({ stdin, stdout, stderr }) do
      s:close()
    end
    local e = uverr(pid)
    if e.code == "ENOENT" then
      e.message = "executable not found: " .. cmd[1]
    end
    return nil, e
  end
  p.handle, p.pid, p.stdin = handle, pid, stdin
  local function reader(pipe, cb)
    pipe:read_start(function(err, chunk)
      if chunk then
        cb(chunk)
      end
      if err or not chunk then
        streams = streams - 1
        pipe:read_stop()
        maybe_done()
      end
    end)
  end
  reader(stdout, cbs.stdout)
  reader(stderr, cbs.stderr)
  return p
end

handlers["proc.spawn"] = function(p, respond)
  local id = p.id
  if procs[id] then
    return respond(fail("EEXIST", "process id in use"))
  end
  local proc, e = spawn(p.cmd, opt(p.cwd), opt(p.env), {
    stdout = function(chunk)
      notify("proc.stdout", { id = id, data = chunk })
    end,
    stderr = function(chunk)
      notify("proc.stderr", { id = id, data = chunk })
    end,
    exit = function(code, signal)
      procs[id] = nil
      notify("proc.exit", { id = id, code = code, signal = signal })
    end,
  })
  if not proc then
    return respond(e)
  end
  procs[id] = proc
  respond(nil, { pid = proc.pid })
end

handlers["proc.write"] = function(p, respond)
  local proc = procs[p.id]
  if proc and not proc.stdin:is_closing() then
    proc.stdin:write(p.data)
  end
  respond(nil, true)
end

handlers["proc.close_stdin"] = function(p, respond)
  local proc = procs[p.id]
  if proc and not proc.stdin:is_closing() then
    proc.stdin:shutdown()
  end
  respond(nil, true)
end

handlers["proc.kill"] = function(p, respond)
  local proc = procs[p.id]
  if proc and not proc.exited then
    pcall(uv.kill, proc.pid, opt(p.signal) or "sigterm")
  end
  respond(nil, true)
end

--- Run a command to completion and return its output.
handlers["exec"] = function(p, respond)
  local outb, errb, total = {}, {}, 0
  local max = opt(p.max_bytes) or (64 * 1024 * 1024)
  local truncated, timed_out = false, false
  local proc, timer
  local e
  proc, e = spawn(p.cmd, opt(p.cwd), opt(p.env), {
    stdout = function(chunk)
      if truncated then
        return
      end
      total = total + #chunk
      outb[#outb + 1] = chunk
      if total > max then
        truncated = true
        pcall(uv.kill, proc.pid, "sigkill")
      end
    end,
    stderr = function(chunk)
      if #errb < 64 then
        errb[#errb + 1] = chunk
      end
    end,
    exit = function(code, signal)
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      respond(nil, {
        code = code,
        signal = signal,
        stdout = table.concat(outb),
        stderr = table.concat(errb),
        truncated = truncated,
        timed_out = timed_out,
      })
    end,
  })
  if not proc then
    return respond(e)
  end
  local stdin = opt(p.stdin)
  if stdin then
    proc.stdin:write(stdin)
  end
  proc.stdin:shutdown()
  local timeout = opt(p.timeout)
  if timeout then
    timer = uv.new_timer()
    timer:start(timeout, 0, function()
      timed_out = true
      pcall(uv.kill, proc.pid, "sigkill")
    end)
  end
end

--- Resolve executables against the agent's PATH.
handlers["which"] = function(p, respond)
  local found = {}
  for _, name in ipairs(p.names or {}) do
    local path = vim.fn.exepath(name)
    found[name] = path ~= "" and path or NIL
  end
  respond(nil, found)
end

-- ---------------------------------------------------------------------------
-- File index: the list of files in a workspace, kept current by watching its
-- folders, so the client can find files without listing them every time.
--
-- The first listing is answered in full; after that the client gets
-- "index.changed" notifications with the files that were added and removed.
-- The listing is the one the client used to run itself: `rg --files` (which
-- leaves out .git and whatever .gitignore excludes) or `find` without .git and
-- node_modules. Only folders that belong to that listing are watched, one
-- (non-recursive) watch each, so ignored folders such as node_modules or build
-- output cost nothing.
-- ---------------------------------------------------------------------------
local indexes = {}
local INDEX_DEBOUNCE = 300

--- Run cmd to completion. cb(stdout, code).
local function collect(cmd, cwd, stdin, cb)
  local outb = {}
  local proc, e = spawn(cmd, cwd, nil, {
    stdout = function(chunk)
      outb[#outb + 1] = chunk
    end,
    stderr = function() end,
    exit = function(code)
      cb(table.concat(outb), code)
    end,
  })
  if not proc then
    return cb("", -1, e)
  end
  if stdin then
    proc.stdin:write(stdin)
  end
  proc.stdin:shutdown()
end

local function rjoin(rel, name)
  return rel == "" and name or (rel .. "/" .. name)
end

local function rsplit(rel)
  local dir, name = rel:match("^(.*)/([^/]*)$")
  if not dir then
    return "", rel
  end
  return dir, name
end

local function under(rel, prefix)
  return prefix == "" or rel == prefix or rel:sub(1, #prefix + 1) == prefix .. "/"
end

local function ix_abs(ix, rel)
  if rel == "" then
    return ix.root
  end
  return (ix.root == "/" and "/" or ix.root .. "/") .. rel
end

--- The path to give a listing command for a folder (never starts with "-").
local function ix_arg(rel)
  return rel == "" and "." or ("./" .. rel)
end

--- Command listing the files under `rels` (relative folders), recursively or
--- only their direct children.
local function ix_list_cmd(ix, rels, shallow)
  local cmd
  if ix.rg then
    cmd = { "rg", "--files", "--hidden", "--glob", "!.git", "--color", "never" }
    if shallow then
      vim.list_extend(cmd, { "--max-depth", "1" })
    end
    cmd[#cmd + 1] = "--"
    for _, rel in ipairs(rels) do
      cmd[#cmd + 1] = ix_arg(rel)
    end
  else
    cmd = { "find" }
    for _, rel in ipairs(rels) do
      cmd[#cmd + 1] = ix_arg(rel)
    end
    if shallow then
      vim.list_extend(cmd, { "-mindepth", "1", "-maxdepth", "1", "-type", "f", "-print" })
    else
      vim.list_extend(cmd, { "-type", "d", "(", "-name", ".git", "-o", "-name", "node_modules", ")", "-prune", "-o", "-type", "f", "-print" })
    end
  end
  return cmd
end

--- Parse listing output into relative paths.
local function ix_parse(out)
  local list = {}
  for line in out:gmatch("[^\n]+") do
    if line:sub(1, 2) == "./" then
      line = line:sub(3)
    end
    if line ~= "" and line ~= "." then
      list[#list + 1] = line
    end
  end
  return list
end

--- List files under `rels` in batches (keeps command lines short). cb(list).
local function ix_list(ix, rels, shallow, cb)
  local all, i = {}, 1
  local function step()
    if i > #rels or not indexes[ix.id] then
      return cb(all)
    end
    local batch = {}
    while i <= #rels and #batch < 500 do
      batch[#batch + 1] = rels[i]
      i = i + 1
    end
    collect(ix_list_cmd(ix, batch, shallow), ix.root, nil, function(out)
      vim.list_extend(all, ix_parse(out))
      vim.schedule(step)
    end)
  end
  step()
end

local function ix_has(ix, rel)
  local dir, name = rsplit(rel)
  local d = ix.dirs[dir]
  return d ~= nil and d[name] == true
end

local function ix_add(ix, rel, added)
  local dir, name = rsplit(rel)
  local d = ix.dirs[dir]
  if not d then
    d = {}
    ix.dirs[dir] = d
  end
  if not d[name] then
    d[name] = true
    ix.count = ix.count + 1
    if added then
      added[#added + 1] = rel
    end
  end
end

local function ix_del(ix, rel, removed)
  local dir, name = rsplit(rel)
  local d = ix.dirs[dir]
  if d and d[name] then
    d[name] = nil
    ix.count = ix.count - 1
    removed[#removed + 1] = rel
    if next(d) == nil then
      ix.dirs[dir] = nil
    end
  end
end

local function ix_unwatch_all(ix)
  for _, w in pairs(ix.watches) do
    pcall(w.stop, w)
    if not w:is_closing() then
      w:close()
    end
  end
  ix.watches = {}
end

--- Give up watching (too many files, or the system's watch limit): the
--- client falls back to listing again now and then.
local function ix_stop_watching(ix, why)
  if not ix.watching then
    return
  end
  ix.watching = false
  ix_unwatch_all(ix)
  if ix.timer and not ix.timer:is_closing() then
    ix.timer:stop()
  end
  ix.pending, ix.dirty = {}, {}
  notify("index.changed", { id = ix.id, overflow = true, reason = why })
end

local ix_queue

local function ix_watch(ix, rel)
  if not ix.watching or ix.watches[rel] then
    return
  end
  local w = uv.new_fs_event()
  if not w then
    return ix_stop_watching(ix, "could not create a watch")
  end
  local ok, e = w:start(ix_abs(ix, rel), {}, function(err, name)
    if err then
      return
    end
    ix_queue(ix, rel, name)
  end)
  if not ok then
    w:close()
    return ix_stop_watching(ix, tostring(e))
  end
  ix.watches[rel] = w
end

local function ix_unwatch(ix, prefix)
  for rel, w in pairs(ix.watches) do
    if under(rel, prefix) then
      pcall(w.stop, w)
      if not w:is_closing() then
        w:close()
      end
      ix.watches[rel] = nil
    end
  end
end

--- Of the folders `rels`, the ones the listing leaves out.
local function ix_ignored(ix, rels, cb)
  local skip, ask = {}, {}
  for _, rel in ipairs(rels) do
    local name = rel:match("([^/]*)$")
    if name == ".git" or (not ix.rg and name == "node_modules") then
      skip[rel] = true
    elseif ix.rg then
      ask[#ask + 1] = rel
    end
  end
  if #ask == 0 or not ix.git then
    return cb(skip)
  end
  -- rg applies .gitignore without looking at the git index; so does this.
  collect({ ix.git, "check-ignore", "--no-index", "--stdin" }, ix.root, table.concat(ask, "/\n") .. "/\n", function(out)
    for line in out:gmatch("[^\n]+") do
      skip[(line:gsub("/$", ""))] = true
    end
    cb(skip)
  end)
end

local function ix_subdirs(ix, rel)
  local list = {}
  local req = uv.fs_scandir(ix_abs(ix, rel))
  if not req then
    return list
  end
  while true do
    local name, t = uv.fs_scandir_next(req)
    if not name then
      break
    end
    if t == "directory" then
      list[#list + 1] = rjoin(rel, name)
    end
  end
  return list
end

--- Folders that are not watched yet (new, moved in, or empty when the index
--- was built): watch those that belong to the listing, level by level, and
--- add the files in them. cb(added, fresh) where fresh lists the folders
--- that are now watched.
local function ix_discover(ix, rels, cb)
  local fresh, tops = {}, {}
  local function level(list, top)
    local todo = {}
    for _, rel in ipairs(list) do
      if not ix.watches[rel] then
        todo[#todo + 1] = rel
      end
    end
    if #todo == 0 or not ix.watching or not indexes[ix.id] then
      return vim.schedule(function()
        if #tops == 0 or not indexes[ix.id] then
          return cb({}, fresh)
        end
        ix_list(ix, tops, false, function(files)
          local added = {}
          for _, f in ipairs(files) do
            ix_add(ix, f, added)
          end
          cb(added, fresh)
        end)
      end)
    end
    ix_ignored(ix, todo, function(skip)
      vim.schedule(function()
        local next_level = {}
        for _, rel in ipairs(todo) do
          if not skip[rel] then
            ix_watch(ix, rel)
            if ix.watches[rel] then
              fresh[#fresh + 1] = rel
              if top then
                tops[#tops + 1] = rel
              end
              vim.list_extend(next_level, ix_subdirs(ix, rel))
            end
          end
        end
        level(next_level, false)
      end)
    end)
  end
  level(rels, true)
end

local function ix_flush(ix)
  if ix.busy or not indexes[ix.id] or not ix.watching then
    return
  end
  local pending, dirty = ix.pending, ix.dirty
  ix.pending, ix.dirty = {}, {}
  if next(pending) == nil and next(dirty) == nil then
    return
  end
  ix.busy = true
  local added, removed = {}, {}
  local new_dirs = {}
  for rel in pairs(pending) do
    local st = uv.fs_lstat(ix_abs(ix, rel))
    if not st then
      -- Gone: a file, or a folder with everything in it.
      ix_del(ix, rel, removed)
      if ix.watches[rel] then
        -- Every folder holding indexed files is watched, so only a watched
        -- folder can take files with it.
        for dir, names in pairs(ix.dirs) do
          if under(dir, rel) then
            for name in pairs(names) do
              ix_del(ix, rjoin(dir, name), removed)
            end
          end
        end
        ix_unwatch(ix, rel)
      end
    elseif st.type == "directory" and not ix.watches[rel] then
      new_dirs[#new_dirs + 1] = rel
    end
    local parent = rsplit(rel)
    if rel ~= "" and ix.watches[parent] then
      dirty[parent] = true
    end
  end
  local shallow = {}
  for rel in pairs(dirty) do
    if ix.watches[rel] and uv.fs_stat(ix_abs(ix, rel)) then
      shallow[#shallow + 1] = rel
    end
  end

  local function done(fresh)
    ix.busy = false
    if not indexes[ix.id] then
      return
    end
    if ix.count > ix.max then
      return ix_stop_watching(ix, "too many files")
    end
    if #added > 0 or #removed > 0 then
      notify("index.changed", { id = ix.id, added = added, removed = removed })
    end
    -- Files can land in a new folder before its watch starts: look again.
    for _, rel in ipairs(fresh or {}) do
      ix.dirty[rel] = true
    end
    if next(ix.pending) ~= nil or next(ix.dirty) ~= nil then
      ix.timer:start(INDEX_DEBOUNCE, 0, function()
        vim.schedule(function()
          ix_flush(ix)
        end)
      end)
    end
  end

  ix_list(ix, shallow, true, function(files)
    if not indexes[ix.id] then
      return done()
    end
    local now = {}
    for _, rel in ipairs(shallow) do
      now[rel] = {}
    end
    for _, f in ipairs(files) do
      local dir, name = rsplit(f)
      if now[dir] then
        now[dir][name] = true
      end
    end
    for dir, names in pairs(now) do
      for name in pairs(names) do
        ix_add(ix, rjoin(dir, name), added)
      end
      for name in pairs(ix.dirs[dir] or {}) do
        if not names[name] then
          ix_del(ix, rjoin(dir, name), removed)
        end
      end
    end
    if #new_dirs == 0 then
      return done()
    end
    ix_discover(ix, new_dirs, function(more, fresh)
      vim.list_extend(added, more)
      done(fresh)
    end)
  end)
end

ix_queue = function(ix, rel, name)
  if not indexes[ix.id] or not ix.watching then
    return
  end
  if name and name ~= "" then
    ix.pending[rjoin(rel, name)] = true
  else
    ix.dirty[rel] = true
  end
  if not ix.busy then
    ix.timer:stop()
    ix.timer:start(INDEX_DEBOUNCE, 0, function()
      vim.schedule(function()
        ix_flush(ix)
      end)
    end)
  end
end

local function ix_free(ix)
  indexes[ix.id] = nil
  ix_unwatch_all(ix)
  if ix.timer and not ix.timer:is_closing() then
    ix.timer:stop()
    ix.timer:close()
  end
end

--- params: id, root, rg (use ripgrep), max (most files), watch (default true).
--- Answers {files, truncated, watching}.
handlers["index.start"] = function(p, respond)
  local root = p.root
  local st = root and uv.fs_stat(root)
  if not st or st.type ~= "directory" then
    return respond(fail("ENOENT", "not a folder: " .. tostring(root)))
  end
  if indexes[p.id] then
    ix_free(indexes[p.id])
  end
  local git = vim.fn.exepath("git")
  local ix = {
    id = p.id,
    root = root,
    rg = opt(p.rg) and true or false,
    git = git ~= "" and git or nil,
    max = opt(p.max) or 200000,
    dirs = {},
    count = 0,
    watches = {},
    pending = {},
    dirty = {},
    watching = opt(p.watch) ~= false,
    timer = uv.new_timer(),
  }
  indexes[ix.id] = ix
  local outb, total, truncated = {}, 0, false
  local max_bytes = ix.max * 120
  local proc, e
  proc, e = spawn(ix_list_cmd(ix, { "" }, false), root, nil, {
    stdout = function(chunk)
      if truncated then
        return
      end
      total = total + #chunk
      outb[#outb + 1] = chunk
      if total > max_bytes then
        truncated = true
        pcall(uv.kill, proc.pid, "sigkill")
      end
    end,
    stderr = function() end,
    exit = function()
      vim.schedule(function()
        if indexes[ix.id] ~= ix then
          return respond(fail("ECANCELED", "index was replaced"))
        end
        local files = ix_parse(table.concat(outb))
        if truncated then
          files[#files] = nil -- possibly cut mid-line
        end
        while #files > ix.max do
          files[#files] = nil
          truncated = true
        end
        for _, f in ipairs(files) do
          ix_add(ix, f)
        end
        if truncated then
          ix.watching = false
        end
        respond(nil, { files = files, truncated = truncated, watching = ix.watching })
        if not ix.watching then
          return
        end
        -- Watch the root and every folder that holds a listed file...
        ix_watch(ix, "")
        for dir in pairs(ix.dirs) do
          local d = dir
          while ix.watching and d ~= "" and not ix.watches[d] do
            ix_watch(ix, d)
            d = rsplit(d)
          end
        end
        if not ix.watching then
          return
        end
        -- ...and folders without files yet (only those the listing covers).
        local others = {}
        for rel in pairs(ix.watches) do
          for _, sub in ipairs(ix_subdirs(ix, rel)) do
            if not ix.watches[sub] then
              others[#others + 1] = sub
            end
          end
        end
        ix.busy = true
        ix_discover(ix, others, function(added)
          ix.busy = false
          if #added > 0 then
            notify("index.changed", { id = ix.id, added = added, removed = {} })
          end
          if next(ix.pending) ~= nil or next(ix.dirty) ~= nil then
            ix_flush(ix)
          end
        end)
      end)
    end,
  })
  if not proc then
    ix_free(ix)
    return respond(e)
  end
  proc.stdin:shutdown()
end

handlers["index.stop"] = function(p, respond)
  local ix = indexes[p.id]
  if ix then
    ix_free(ix)
  end
  respond(nil, true)
end

-- ---------------------------------------------------------------------------
-- Language server installation through mason.nvim (running here, on the
-- server, so packages are built for and installed on this machine).
-- ---------------------------------------------------------------------------
local mason_ready = false

local function mason()
  if not mason_ready then
    local dir = base .. "/plugins/mason.nvim"
    if not uv.fs_stat(dir .. "/lua/mason/init.lua") then
      return nil, fail("ENOMASON", "mason.nvim is not installed on the server")
    end
    vim.opt.runtimepath:prepend(dir)
    local ok, e = pcall(function()
      require("mason").setup({ install_root_dir = base .. "/mason", PATH = "skip" })
    end)
    if not ok then
      return nil, fail("EMASON", "mason.nvim failed to load: " .. tostring(e))
    end
    mason_ready = true
  end
  return require("mason-registry")
end

local function with_registry(respond, fn)
  local registry, e = mason()
  if not registry then
    return respond(e)
  end
  local ok, re = pcall(registry.refresh, function()
    vim.schedule(function()
      local fok, fe = pcall(fn, registry)
      if not fok then
        respond(fail("EMASON", tostring(fe)))
      end
    end)
  end)
  if not ok then
    respond(fail("EMASON", tostring(re)))
  end
end

--- Find the mason package providing an lspconfig server name.
handlers["mason.resolve"] = function(p, respond)
  with_registry(respond, function(registry)
    local found
    for _, spec in ipairs(registry.get_all_package_specs()) do
      local nv = spec.neovim
      if type(nv) == "table" and nv.lspconfig == p.server then
        found = spec.name
        break
      end
    end
    if not found and registry.has_package(p.server) then
      found = p.server
    end
    if not found then
      return respond(nil, { package = NIL })
    end
    local pkg = registry.get_package(found)
    respond(nil, { package = found, installed = pkg:is_installed() })
  end)
end

handlers["mason.install"] = function(p, respond)
  with_registry(respond, function(registry)
    local pkg = registry.get_package(p.package)
    if pkg:is_installed() then
      return respond(nil, { ok = true })
    end
    local log = {}
    local function line(text)
      text = tostring(text)
      log[#log + 1] = text
      if #log > 40 then
        table.remove(log, 1)
      end
      notify("mason.progress", { package = p.package, text = text })
    end
    local handle = pkg:install({}, function(success, err)
      vim.schedule(function()
        if success then
          respond(nil, { ok = true })
        else
          respond(fail("EINSTALL", tostring(err) .. "\n" .. table.concat(log)))
        end
      end)
    end)
    if type(handle) == "table" and handle.on then
      pcall(handle.on, handle, "stdout", line)
      pcall(handle.on, handle, "stderr", line)
    end
  end)
end

handlers["shutdown"] = function(_, respond)
  respond(nil, true)
  vim.schedule(shutdown)
end

-- Tell the client we are up, then serve until stdin closes.
notify("agent.ready", { agent = AGENT_VERSION })

while not quitting do
  vim.wait(3600000, function()
    return quitting
  end, 500)
end
