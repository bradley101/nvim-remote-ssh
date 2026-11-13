local H, T = ...
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local search = require("remote-ssh.search")
local symbols = require("remote-ssh.symbols")
local D = T.W .. "/proj"
vim.fn.delete(D, "rf")
vim.fn.mkdir(D .. "/src/.git", "p")
vim.fn.mkdir(D .. "/a dir", "p")
local function put(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
put(D .. "/src/main.c", [[
#include <stdio.h>
struct point { int x; int y; };
enum color { RED, GREEN };
static int add(int a, int b) { return a + b; }
int *make(void);
int main(void) {
  struct point p;
  printf("needle %d\n", add(1, 2));
  return 0;
}
]])
put(D .. "/src/mod.lua", [[
local M = {}
local function helper(x) return x end
function M.run(a)
  local function inner() return helper(a) end
  return inner()
end
function M:method() end
return M
]])
put(D .. "/a dir/notes with space.txt", "a Needle in a haystack\nnothing\n")
put(D .. "/src/.git/config", "needle in git dir\n")

local conn = require("remote-ssh.connection").get("direct")

local function with_tools(rg, fn)
  conn.tools = rg and nil or { rg = false }
  local okk, err = pcall(fn)
  conn.tools = nil
  if not okk then error(err, 0) end
end

for _, rg in ipairs({ true, false }) do
  local label = rg and "ripgrep" or "find/grep fallback"
  test("lists workspace files with " .. label, function()
    with_tools(rg, function()
      local files
      search.files(conn, D, function(err, list) assert(not err, vim.inspect(err)); files = list end)
      wait(function() return files end, 10000, "file list")
      table.sort(files)
      eq(files, { "a dir/notes with space.txt", "src/main.c", "src/mod.lua" })
    end)
  end)

  test("greps the workspace with " .. label, function()
    with_tools(rg, function()
      local got, done = {}, nil
      search.grep(conn, D, "needle", {}, function(batch) vim.list_extend(got, batch) end, function(info) done = info end)
      wait(function() return done end, 10000, "grep")
      eq(done.error, nil)
      table.sort(got, function(a, b) return a.file < b.file end)
      eq(#got, 2)
      eq(got[1].file, "a dir/notes with space.txt")
      eq(got[1].lnum, 1)
      eq(got[2].file, "src/main.c")
      eq(got[2].lnum, 8)
      match(got[2].text, "printf")
    end)
  end)
end

test("grep: no matches, invalid pattern, result cap, quickfix", function()
  local done
  search.grep(conn, D, "zzz_not_there", {}, function() error("unexpected") end, function(info) done = info end)
  wait(function() return done end, 10000)
  eq(done, {})

  done = nil
  search.grep(conn, D, "(unclosed", {}, function() end, function(info) done = info end)
  wait(function() return done end, 10000)
  ok(done.error, "expected an error for an invalid regex")

  done = nil
  local n = 0
  search.grep(conn, D, ".", { max = 3 }, function(b) n = n + #b end, function(info) done = info end)
  wait(function() return done end, 10000)
  eq(n, 3)
  eq(done.truncated, true)

  done = nil
  search.grep_to_quickfix(conn, D, "needle", function(info) done = info end)
  wait(function() return done end, 10000)
  local qf = vim.fn.getqflist()
  eq(#qf, 2)
  vim.cmd("cfirst")
  match(vim.api.nvim_buf_get_name(0), "^rssh://direct" .. D:gsub("%-", "%%-"))
end)

test("treesitter symbols: C", function()
  vim.cmd("edit rssh://direct" .. D .. "/src/main.c")
  local list, why = symbols.get(0)
  ok(list, why)
  local names = vim.tbl_map(function(s) return s.kind .. " " .. s.name .. "@" .. s.lnum end, list)
  eq(names, { "Struct point@2", "Enum color@3", "Function add@4", "Function main@6" })
end)

test("treesitter symbols: Lua, nested", function()
  vim.cmd("edit rssh://direct" .. D .. "/src/mod.lua")
  local list, why = symbols.get(0)
  ok(list, why)
  local names = vim.tbl_map(function(s) return string.rep(">", s.depth) .. s.name end, list)
  eq(names, { "helper", "M.run", ">inner", "M:method" })
end)

test("symbols: clear reason when there is no parser", function()
  vim.cmd("edit rssh://direct" .. D .. "/a\\ dir/notes\\ with\\ space.txt")
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false), { "a Needle in a haystack" })
  local list, why = symbols.get(0)
  eq(list, nil)
  match(why, "no treesitter parser")
end)
