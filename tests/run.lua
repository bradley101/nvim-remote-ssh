local H = dofile("tests/harness.lua")
local test, eq, ok, match, wait = H.test, H.eq, H.ok, H.match, H.wait
local W = os.getenv("RSSH_TEST_DIR")

local prompts, confirms = {}, {}
local answers = {} -- queue of confirm answers; default 1
local ctx = { inputs = {} }
require("remote-ssh").setup({
  ssh = { config_file = W .. "/ssh_config", connect_timeout = 5 },
  remote = { dir = W .. "/remote/nvim-remote-ssh", min_nvim = "0.9.0" },
  sources = { ripgrep = { enabled = false } },
  lsp = { auto_install = false },
  reconnect = { delays = { 1 } },
  ui = {
    notify = function(msg, level)
      io.stdout:write(("     [notify %s] %s\n"):format(tostring(level), (msg:gsub("\n", "\n       "))))
    end,
    confirm = function(msg, choices)
      confirms[#confirms + 1] = msg
      local a = table.remove(answers, 1)
      return a or 1
    end,
    input = function(prompt) ctx.last_input_prompt = prompt return table.remove(ctx.inputs, 1) end,
  },
})
vim.cmd("runtime plugin/remote-ssh.lua")
local connection = require("remote-ssh.connection")
local askpass = require("remote-ssh.askpass")
askpass.handler = function(prompt, kind)
  prompts[#prompts + 1] = prompt
  if prompt:find("continue connecting", 1, true) then return "yes" end
  if prompt:find("password", 1, true) then return "test-password" end
  return nil
end

local function connect(host, opts)
  local done, rerr, rconn
  connection.connect(host, opts or {}, function(err, conn) done, rerr, rconn = true, err, conn end)
  wait(function() return done end, 60000, "connect " .. host)
  return rconn, rerr
end

test("connects to a direct host, accepting the host key via askpass", function()
  local conn, err = connect("direct")
  ok(conn, "connect failed: " .. require("remote-ssh.util").errmsg(err or ""))
  eq(conn.state, "connected")
  match(prompts[1], "continue connecting")
  eq(conn.agent.agent, 1)
  eq(conn.home, "/root")
end)

for _, f in ipairs(vim.fn.glob("tests/spec_*.lua", false, true)) do
  local chunk = assert(loadfile(f))
  ctx.W, ctx.connect, ctx.prompts, ctx.confirms, ctx.answers = W, connect, prompts, confirms, answers
  chunk(H, ctx)
end

connection.close_all()
H.finish()
