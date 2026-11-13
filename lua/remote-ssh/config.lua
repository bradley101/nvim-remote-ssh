local M = {}

M.defaults = {
  ssh = {
    cmd = "ssh",
    -- Extra arguments passed to every ssh invocation.
    args = {},
    -- Alternative ssh config file (default: ~/.ssh/config).
    config_file = nil,
    connect_timeout = 15,
    -- Seconds the shared connection stays open after the last use.
    control_persist = 600,
  },
  remote = {
    -- Install directory on the server. nil = ${XDG_DATA_HOME:-~/.local/share}/nvim-remote-ssh
    dir = nil,
    -- Use the server's own nvim (if new enough) instead of downloading one.
    use_system_nvim = true,
    min_nvim = "0.10.0",
    -- Ask once per host before downloading anything.
    confirm_install = true,
    -- Free space (KB) required for a first-time install.
    min_free_kb = 150 * 1024,
  },
  -- Where server-side components come from. Override to use a mirror.
  sources = {
    connectivity_url = "https://github.com",
    nvim = {
      version = "v0.11.5",
      url = "https://github.com/neovim/neovim/releases/download/{version}/{asset}",
      checksums = "https://github.com/neovim/neovim/releases/download/{version}/shasum.txt",
      -- Builds for old glibc, tried when the official build cannot run.
      compat_url = "https://github.com/neovim/neovim-releases/releases/download/{version}/{asset}",
    },
    ripgrep = {
      enabled = true,
      version = "14.1.1",
      url = "https://github.com/BurntSushi/ripgrep/releases/download/{version}/{asset}",
      checksums = "https://github.com/BurntSushi/ripgrep/releases/download/{version}/{asset}.sha256",
    },
    mason = {
      version = "v2.0.1",
      url = "https://github.com/mason-org/mason.nvim/archive/refs/tags/{version}.tar.gz",
    },
  },
  lsp = {
    enabled = true,
    -- nil = every server enabled with vim.lsp.enable(); or a list of names.
    servers = nil,
    -- Offer to install missing language servers on the server (via mason).
    auto_install = true,
    -- Per-server settings used for remote buffers only, merged over
    -- vim.lsp.config[name]; e.g. { clangd = { cmd = { "clangd-18" } } }
    configs = {},
  },
  files = {
    max_size = 50 * 1024 * 1024,
    -- Reload buffers when the file changes on the server.
    watch = true,
  },
  search = {
    max_files = 200000,
    max_grep_results = 2000,
  },
  tree = {
    width = 34,
    show_hidden = true,
  },
  reconnect = {
    auto = true,
    delays = { 2, 5, 15 },
  },
  -- Request timeout (ms) for blocking operations such as reading a file.
  timeout = 20000,
  -- UI hooks; nil = built-in prompts.
  ui = {
    notify = nil, -- function(msg, level, opts)
    confirm = nil, -- function(msg, choices) -> index (0 = cancelled)
    input = nil, -- function(prompt, default) -> string|nil
    secret = nil, -- function(prompt) -> string|nil
  },
}

local current = vim.deepcopy(M.defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return current
end

function M.get()
  return current
end

return M
