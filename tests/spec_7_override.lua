local H, T = ...
local test, eq, ok = H.test, H.eq, H.ok
local rs = require("remote-ssh")

-- Stand-ins for telescope: record which implementation a call reached.
local calls = {}
local files_mod = {}
for _, name in ipairs({ "find_files", "live_grep", "grep_string" }) do
  files_mod[name] = function(opts) calls[#calls + 1] = { "local", name, opts } end
end
local builtin = {}
for name in pairs(files_mod) do
  builtin[name] = function(opts) return package.loaded["telescope.builtin.__files"][name](opts) end
end
local captured = builtin.find_files -- a mapping that grabbed the function early
package.loaded["telescope"] = {}
package.loaded["telescope.builtin"] = builtin
package.loaded["telescope.builtin.__files"] = files_mod
package.loaded["remote-ssh.telescope"] = {
  files = function(opts) calls[#calls + 1] = { "remote", "files", opts } end,
  live_grep = function(opts) calls[#calls + 1] = { "remote", "live_grep", opts } end,
}
require("remote-ssh.override").install()

local function last() return calls[#calls] end
local D = T.W .. "/ws"

test("telescope builtins search the remote workspace from remote buffers", function()
  rs.workspaces.direct, rs.current = D, { host = "direct", root = D }
  vim.cmd("edit rssh://direct" .. D .. "/README.md")
  builtin.find_files()
  eq({ last()[1], last()[2] }, { "remote", "files" })
  eq(last()[3].root, D)
  eq(last()[3].conn.host, "direct")
  builtin.live_grep({})
  eq({ last()[1], last()[2] }, { "remote", "live_grep" })
  captured({})
  eq(last()[1], "remote", "a function reference captured before install is covered too")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "needle here" })
  builtin.grep_string({})
  eq({ last()[1], last()[2], last()[3].default_text }, { "remote", "live_grep", "needle" })
  vim.cmd("edit!")
end)

test("...and from an empty buffer while a workspace is open (nvim started elsewhere)", function()
  vim.cmd("enew")
  builtin.find_files()
  eq(last()[1], "remote")
end)

test("local files, explicit directories and no workspace stay local", function()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
  builtin.find_files()
  eq(last()[1], "local")
  vim.cmd("edit rssh://direct" .. D .. "/README.md")
  builtin.find_files({ cwd = "/etc" })
  eq(last()[1], "local")
  eq(last()[3].cwd, "/etc")
  vim.cmd("enew")
  local saved = rs.current
  rs.current = nil
  builtin.live_grep()
  eq(last()[1], "local")
  rs.current = saved
end)

test("a disconnected remote workspace does not silently search the local disk", function()
  local conn = require("remote-ssh.connection").get("direct")
  local state = conn.state
  conn.state = "disconnected"
  vim.cmd("edit rssh://direct" .. D .. "/README.md")
  local n = #calls
  builtin.find_files()
  conn.state = state
  eq(#calls, n)
end)

for _, m in ipairs({ "telescope", "telescope.builtin", "telescope.builtin.__files", "remote-ssh.telescope" }) do
  package.loaded[m] = nil
end
