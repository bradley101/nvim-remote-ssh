local H, T = ...
local test, eq, ok, wait = H.test, H.eq, H.ok, H.wait
local filecache = require("remote-ssh.filecache")
local search = require("remote-ssh.search")
local D = T.W .. "/fc"
local function put(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(data or "")
  f:close()
end
local function setup_tree()
  vim.fn.delete(D, "rf")
  vim.fn.mkdir(D, "p")
  vim.fn.system({ "git", "init", "-q", D })
  put(D .. "/.gitignore", "build/\n*.log\n")
  put(D .. "/README.md", "# hi\n")
  put(D .. "/src/main.c", "int main;\n")
  put(D .. "/src/lib/util.c", "")
  put(D .. "/build/out.o", "")
  vim.fn.mkdir(D .. "/empty", "p")
end

local conn

local function connect()
  conn = require("remote-ssh.connection").get("direct")
  if not conn or conn.state ~= "connected" then
    conn = T.connect("direct")
  end
end

local function sorted(list)
  local copy = vim.list_extend({}, list or {})
  table.sort(copy)
  return copy
end

local function get()
  local files, done
  filecache.get(conn, D, function(err, list)
    assert(not err, vim.inspect(err))
    files, done = list, true
  end)
  wait(function() return done end, 10000, "file list")
  return files
end

local function has(rel)
  local c = filecache.caches.direct and filecache.caches.direct[D]
  return c ~= nil and c.pos[rel] ~= nil
end

local function with_tools(rg, fn)
  connect()
  if rg then
    conn.tools = nil
  else
    conn.tools = { rg = false }
  end
  filecache.drop("direct")
  local okk, err = pcall(fn)
  filecache.drop("direct")
  conn.tools = nil
  if not okk then
    error(err, 0)
  end
end

for _, rg in ipairs({ true, false }) do
  local label = rg and "ripgrep" or "find"
  test("file cache: lists once, then answers from the cache (" .. label .. ")", function()
    with_tools(rg, function()
      setup_tree()
      local first = get()
      local expected
      search.files(conn, D, function(_, list) expected = list end)
      wait(function() return expected end, 10000, "search.files")
      eq(sorted(first), sorted(expected))
      -- Cached: the callback runs before get() returns, with no request.
      local sync = false
      local requests = 0
      local orig = conn.request
      conn.request = function(...) requests = requests + 1 return orig(...) end
      filecache.get(conn, D, function() sync = true end)
      conn.request = orig
      ok(sync, "cached list was not returned synchronously")
      eq(requests, 0)
      ok(filecache.caches.direct[D].watching, "the server is not watching")
      eq(conn.tools.rg ~= false, rg)
    end)
  end)

  test("file cache: files created and deleted on the server are picked up (" .. label .. ")", function()
    with_tools(rg, function()
      setup_tree()
      get()
      put(D .. "/new.txt", "x")
      put(D .. "/src/lib/more.c", "x")
      wait(function() return has("new.txt") and has("src/lib/more.c") end, 5000, "new files")
      os.remove(D .. "/new.txt")
      wait(function() return not has("new.txt") end, 5000, "deleted file")
      -- A file in a folder that was empty when the list was made.
      put(D .. "/empty/first.txt", "x")
      wait(function() return has("empty/first.txt") end, 5000, "file in empty folder")
    end)
  end)

  test("file cache: new, moved and deleted folders (" .. label .. ")", function()
    with_tools(rg, function()
      setup_tree()
      get()
      -- mkdir -p of a deep folder, then files in it.
      vim.fn.mkdir(D .. "/pkg/a/b", "p")
      put(D .. "/pkg/top.txt", "x")
      wait(function() return has("pkg/top.txt") end, 5000, "file in new folder")
      put(D .. "/pkg/a/b/deep.txt", "x")
      wait(function() return has("pkg/a/b/deep.txt") end, 5000, "file in new deep folder")
      -- A whole tree moved in at once.
      local tmp = T.W .. "/fc-incoming"
      vim.fn.delete(tmp, "rf")
      put(tmp .. "/x/y.txt", "x")
      put(tmp .. "/z.txt", "x")
      os.rename(tmp, D .. "/incoming")
      wait(function() return has("incoming/x/y.txt") and has("incoming/z.txt") end, 5000, "moved-in folder")
      -- Renamed folder.
      os.rename(D .. "/pkg", D .. "/pkg2")
      wait(function() return has("pkg2/a/b/deep.txt") and not has("pkg/a/b/deep.txt") end, 5000, "renamed folder")
      -- Deleted folder.
      vim.fn.delete(D .. "/pkg2", "rf")
      wait(function() return not has("pkg2/top.txt") and not has("pkg2/a/b/deep.txt") end, 5000, "deleted folder")
      -- Edits keep working after all that.
      put(D .. "/incoming/x/later.txt", "x")
      wait(function() return has("incoming/x/later.txt") end, 5000, "file after moves")
    end)
  end)
end

test("file cache: ignored and .git files are left out", function()
  with_tools(true, function()
    setup_tree()
    local files = get()
    ok(not vim.tbl_contains(files, "build/out.o"), "ignored file listed")
    put(D .. "/build/new.o", "x")
    put(D .. "/src/trace.log", "x")
    put(D .. "/.git/whatever", "x")
    vim.fn.mkdir(D .. "/build/sub", "p")
    put(D .. "/build/sub/x.o", "x")
    -- Then a file that does count, to know the batch was processed.
    put(D .. "/src/ok.c", "x")
    wait(function() return has("src/ok.c") end, 5000, "file after ignored ones")
    vim.wait(800)
    ok(not has("build/new.o") and not has("build/sub/x.o"), "file in ignored folder added")
    ok(not has("src/trace.log"), "ignored file added")
    ok(not has(".git/whatever"), ".git file added")
  end)
end)

test("file cache: changes made from Neovim apply at once", function()
  with_tools(true, function()
    setup_tree()
    get()
    filecache.added("direct", D .. "/made/here.txt")
    ok(has("made/here.txt"))
    filecache.renamed("direct", D .. "/src", D .. "/source")
    ok(has("source/main.c") and has("source/lib/util.c") and not has("src/main.c"), "rename")
    filecache.removed("direct", D .. "/source")
    ok(not has("source/main.c") and not has("source/lib/util.c"), "remove")
    filecache.added("direct", "/elsewhere/file") -- outside the workspace: ignored
    ok(not has("/elsewhere/file") and not has("elsewhere/file"))
  end)
end)

test("file cache: dropped on disconnect, rebuilt for the workspace on reconnect", function()
  local jconn = T.connect("jumped")
  ok(jconn and jconn.state == "connected", "jumped not connected")
  setup_tree()
  local rs = require("remote-ssh")
  local saved = rs.workspaces.jumped
  rs.workspaces.jumped = D
  local okk, err = pcall(function()
    local got
    filecache.get(jconn, D, function(e, list) got = not e and list end)
    wait(function() return got end, 10000, "jumped file list")
    jconn:close()
    wait(function() return jconn.state == "disconnected" end, 5000, "close")
    ok(filecache.caches.jumped == nil, "cache kept after disconnect")
    jconn = T.connect("jumped")
    ok(jconn and jconn.state == "connected", "reconnect failed")
    wait(function() return filecache.ready("jumped", D) end, 10000, "rebuilt list")
  end)
  rs.workspaces.jumped = saved
  filecache.drop("jumped")
  if not okk then
    error(err, 0)
  end
end)

test("file cache: too many files to watch: cached list, refreshed in the background", function()
  with_tools(true, function()
    setup_tree()
    local cfg = require("remote-ssh.config").get().search
    local saved = cfg.max_files
    cfg.max_files = 2
    local okk, err = pcall(function()
      local files, truncated
      filecache.get(conn, D, function(e, list, t) assert(not e) files, truncated = list, t end)
      wait(function() return files end, 10000, "truncated list")
      ok(truncated, "not truncated")
      local c = filecache.caches.direct[D]
      ok(not c.watching, "watching a truncated list")
      eq(#files, 2)
      local before = c.id
      c.fetched_at = 0 -- pretend it is old
      local sync = false
      filecache.get(conn, D, function() sync = true end)
      ok(sync, "an old list was not used right away")
      wait(function() return c.id ~= before and not c.fetching end, 10000, "background refresh")
    end)
    cfg.max_files = saved
    if not okk then
      error(err, 0)
    end
  end)
end)
