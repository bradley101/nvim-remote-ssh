-- Minimal config for recording the README demo:  vhs demo/demo.tape
-- Plugins are taken from lazy.nvim's directory; RSSH_DEMO_SSH_CONFIG may
-- point at an ssh config of its own (default: ~/.ssh/config).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local lazy = vim.fn.stdpath("data"):gsub("rssh%-demo$", "nvim") .. "/lazy"
for _, p in ipairs({ "plenary.nvim", "telescope.nvim", "nvim-web-devicons" }) do
  vim.opt.rtp:append(lazy .. "/" .. p)
end
vim.opt.rtp:prepend(root)

vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 3
vim.o.showmode = false
vim.o.shortmess = vim.o.shortmess .. "I"
vim.cmd.colorscheme("habamax")

require("telescope").setup({
  defaults = { sorting_strategy = "ascending", layout_config = { prompt_position = "top" } },
})
require("remote-ssh").setup({
  ssh = { config_file = os.getenv("RSSH_DEMO_SSH_CONFIG") },
  open = { window = "same" },
})
vim.o.statusline = " %f %m%= %{v:lua.require'remote-ssh'.statusline()} "
