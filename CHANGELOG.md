# Changelog

## 0.1.0

First tagged release.

- Open remote workspaces over SSH (`:RemoteSSH open`), hosts from `~/.ssh/config`
  including `ProxyJump` chains; jump-host connections are shared.
- Zero-setup servers: Neovim, ripgrep and mason.nvim are installed on first
  connect into one directory, after one confirmation.
- Remote buffers with atomic saves, conflict detection and automatic reload.
- File explorer, find files (cached and kept current by watching the server),
  live grep, symbols and outline.
- Language servers run on the server and attach to Neovim's built-in client.
- Remote terminal, port forwarding, reconnects, session restore.
- Connection progress window, dialogs for passwords and confirmations.
- Workspaces open in their own Neovim when this one is already in use.
