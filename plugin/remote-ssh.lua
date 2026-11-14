if vim.g.loaded_remote_ssh then
  return
end
vim.g.loaded_remote_ssh = true

if vim.fn.has("nvim-0.9") ~= 1 then
  vim.notify("remote-ssh requires Neovim 0.11 or newer", vim.log.levels.ERROR)
  return
end

-- Register rssh:// handling with default options; a later
-- require("remote-ssh").setup({...}) only replaces the options.
require("remote-ssh").setup()

local subcommands = {
  connect = function(a) require("remote-ssh").connect(a[1]) end,
  open = function(a) require("remote-ssh").open(a[1], a[2]) end,
  recent = function() require("remote-ssh").recent() end,
  disconnect = function(a) require("remote-ssh").disconnect(a[1]) end,
  reconnect = function(a) require("remote-ssh").reconnect(a[1]) end,
  files = function() require("remote-ssh").files() end,
  reindex = function(a) require("remote-ssh").reindex(a[1]) end,
  grep = function(a) require("remote-ssh").grep(table.concat(a, " ")) end,
  symbols = function() require("remote-ssh").symbols() end,
  outline = function() require("remote-ssh").outline() end,
  tree = function() require("remote-ssh").tree() end,
  terminal = function() require("remote-ssh").terminal() end,
  forward = function(a) require("remote-ssh").forward(a[1]) end,
  unforward = function(a) require("remote-ssh").unforward(a[1]) end,
  info = function() require("remote-ssh").info() end,
  log = function() require("remote-ssh.log").show() end,
  setup = function(a) require("remote-ssh").setup_host(a[1]) end,
  uninstall = function(a) require("remote-ssh").uninstall(a[1]) end,
}
local takes_host = { connect = true, open = true, disconnect = true, reconnect = true, reindex = true, setup = true, uninstall = true }

vim.api.nvim_create_user_command("RemoteSSH", function(cmd)
  local args = cmd.fargs
  local name = table.remove(args, 1) or "open"
  local fn = subcommands[name]
  if not fn then
    local names = vim.tbl_keys(subcommands)
    table.sort(names)
    return vim.notify(("RemoteSSH: unknown subcommand %q. Available: %s"):format(name, table.concat(names, ", ")), vim.log.levels.ERROR)
  end
  fn(args)
end, {
  nargs = "*",
  desc = "Work on a remote machine over SSH",
  complete = function(lead, line)
    local words = vim.split(line, "%s+")
    if #words <= 2 then
      local names = vim.tbl_keys(subcommands)
      table.sort(names)
      return vim.tbl_filter(function(n) return n:sub(1, #lead) == lead end, names)
    end
    if #words == 3 and takes_host[words[2]] then
      return vim.tbl_filter(function(h) return h:sub(1, #lead) == lead end, require("remote-ssh.ssh_config").hosts())
    end
    return {}
  end,
})
