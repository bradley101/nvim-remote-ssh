-- A shell on the server in a terminal window, over the shared connection.
local ssh = require("remote-ssh.ssh")
local util = require("remote-ssh.util")

local M = {}

function M.open(host, cwd)
  local inner = ('cd %s 2>/dev/null; exec "${SHELL:-sh}" -l'):format(util.shq(cwd or "."))
  local cmd = { ssh.cmd() }
  vim.list_extend(cmd, ssh.base_args(host))
  vim.list_extend(cmd, { "-t", "--", host, "exec sh -c " .. util.shq(inner) })
  vim.cmd("botright 15new")
  local ok, err
  if vim.fn.has("nvim-0.11") == 1 then
    ok, err = pcall(vim.fn.jobstart, cmd, { term = true, env = ssh.env() })
  else
    ok, err = pcall(vim.fn.termopen, cmd, { env = ssh.env() })
  end
  if not ok then
    vim.cmd("bwipeout!")
    return require("remote-ssh.log").error("Could not open a terminal: " .. tostring(err))
  end
  pcall(vim.api.nvim_buf_set_name, 0, ("rssh-term://%s/%d"):format(host, vim.api.nvim_get_current_buf()))
  vim.cmd("startinsert")
end

return M
