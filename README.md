# nvim-remote-ssh

Work on a remote machine from your local Neovim, the way VS Code Remote-SSH
does: your editor, config and plugins stay local; files, search and language
servers live on the server.

```
 local Neovim (UI, buffers, treesitter, your plugins)
        │  one shared OpenSSH connection (ProxyJump etc. from ~/.ssh/config)
        ▼
 remote agent (headless Neovim) ── file I/O, file watching, ripgrep,
                                   language servers, mason
```

## Features

- **Hosts from your ssh config**, including `ProxyJump` / `ProxyCommand`
  chains, `Include`, keys, agents. The system `ssh` binary does the work.
- **Prompts inside Neovim**: passwords, key passphrases, one-time codes and
  host-key confirmation.
- **Zero-setup servers**: on first connect the plugin inspects the server and,
  after one confirmation, downloads what is missing into a single directory
  (no root, nothing else touched).
- **Remote buffers** (`rssh://host/path`): atomic saves, permissions kept,
  conflict detection when the file changed on the server, automatic reload.
- **File explorer** with create / rename / copy / delete.
- **Find files and live grep** on the server (ripgrep, or grep/find).
- **Symbols and outline** from treesitter (functions, methods, classes...).
- **LSP**: language servers run on the server and attach to Neovim's built-in
  client; missing servers can be installed there through mason.
- **Remote terminal** and **port forwarding**.
- **Reconnects** after a dropped connection; unsaved edits are never discarded.

## Requirements (your machine)

| Dependency | Required | Used for |
|---|---|---|
| Neovim 0.11+ | yes | |
| OpenSSH client (`ssh`), 8.4+ recommended | yes | all transport |
| [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) + plenary.nvim | recommended | pickers (falls back to `vim.ui.select` / quickfix) |
| treesitter parsers for your languages | for symbols | e.g. via nvim-treesitter |
| nvim-lspconfig or your own `vim.lsp.config()` entries | for LSP | server definitions |

Linux, macOS or WSL. Native Windows is not supported.

## Requirements (the server)

Linux or macOS, a POSIX `sh`, `tar`, `gzip`, `curl` or `wget`, and internet
access for the first connect. Everything else is installed automatically into
`~/.local/share/nvim-remote-ssh`:

- Neovim (runs the agent) — skipped when the server already has Neovim 0.10+
- ripgrep — skipped when the server has `rg`; optional
- mason.nvim — installs language servers on request; optional

If the server has no internet access the first login fails with a message
saying so. `:RemoteSSH uninstall <host>` removes the directory again.

## Install

lazy.nvim:

```lua
{
  "bradley101/nvim-remote-ssh",
  dependencies = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
  lazy = false,
  opts = {},
}
```

`lazy = false` matters if your lazy.nvim setup lazy-loads by default (LazyVim
and other distributions set `defaults.lazy = true`): without it the plugin
stays under "Not Loaded" and `:RemoteSSH` does not exist. Loading is cheap;
nothing connects until you run a command. To lazy-load instead, use
`cmd = "RemoteSSH", event = "BufReadCmd rssh://*"` in place of `lazy = false`.

## Usage

```vim
:RemoteSSH open              " pick a host, then a folder
:RemoteSSH open myhost ~/src/project
```

| Command | |
|---|---|
| `:RemoteSSH open [host] [folder]` | connect and open a workspace |
| `:RemoteSSH connect [host]` | connect only |
| `:RemoteSSH recent` | recently opened workspaces |
| `:RemoteSSH files` | find a file |
| `:RemoteSSH grep [pattern]` | live grep (with a pattern: results to quickfix) |
| `:RemoteSSH symbols` / `outline` | symbols of the current buffer |
| `:RemoteSSH tree` | toggle the explorer (`?` inside it lists its keys) |
| `:RemoteSSH terminal` | shell in the workspace folder |
| `:RemoteSSH forward 8080[:3000]` / `unforward` | forward a local port |
| `:RemoteSSH disconnect` / `reconnect` | |
| `:RemoteSSH info` / `log` | state and diagnostics |
| `:RemoteSSH setup <host>` | retry optional downloads that failed |
| `:RemoteSSH uninstall <host>` | remove everything installed on the server |

While a remote workspace is in use, telescope's own `find_files`, `live_grep`
and `grep_string` search that workspace, so existing mappings such as
`<leader>ff` keep working; from a local file's buffer they search locally as
before. Set `telescope = { override_builtins = false }` to turn this off.

The pickers are also available as `:Telescope remote_ssh
{hosts,recent,files,live_grep,symbols}`. `require("remote-ssh").statusline()`
returns a string for your statusline. `:checkhealth remote-ssh` checks both
ends.

### Language servers

Servers you enabled with `vim.lsp.enable()` are started on the server for
remote buffers, using the same definitions. When a server's executable is
missing there you are asked once whether to install it through mason; packages
that need a runtime (Node, Go, ...) need that runtime on the server.

```lua
require("remote-ssh").setup({
  lsp = {
    servers = { "lua_ls", "clangd" },          -- default: all enabled servers
    configs = { clangd = { cmd = { "clangd-18" } } },  -- remote-only overrides
  },
})
```

## Configuration

Defaults are in [`lua/remote-ssh/config.lua`](lua/remote-ssh/config.lua).
Commonly changed:

```lua
require("remote-ssh").setup({
  remote = {
    dir = nil,                 -- install directory on servers
    use_system_nvim = true,    -- reuse the server's nvim when new enough
    confirm_install = true,    -- ask once per host before downloading
  },
  sources = { ... },           -- download URLs and versions (for mirrors)
  files = { watch = true, max_size = 50 * 1024 * 1024 },
  reconnect = { auto = true, delays = { 2, 5, 15 } },
})
```

## Security notes

- Downloads are verified against published SHA-256 checksums. A mismatch
  aborts; if no checksum can be obtained you are asked before continuing.
  mason.nvim is fetched as a tagged source archive over HTTPS (no checksum is
  published for it).
- A changed host key is never accepted automatically.
- The protocol is one-way: the client sends requests, the agent answers. A
  compromised server cannot run commands in your Neovim. File contents and
  language-server messages from the server are, of course, shown to you.

## Development

```sh
tests/run.sh
```

runs the suite against a throwaway local `sshd` (needs root, `sshd`,
`python3`): direct, jump-host and password logins, connection errors, the
installer (served from a local fake release server), remote buffers, search,
symbols, LSP through a fake language server, the explorer, port forwarding
and reconnects.

Not yet covered by automated tests: the Telescope front-ends, downloads from
the real GitHub release URLs, the real mason.nvim, macOS servers, and the
Neovim 0.11+ discovery of servers enabled with `vim.lsp.enable()` (the suite
passes `lsp.configs` explicitly so it can also run on older Neovim builds).
