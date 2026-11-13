local M = {}

function M.check()
  local h = vim.health
  local start = h.start or h.report_start
  local ok = h.ok or h.report_ok
  local warn = h.warn or h.report_warn
  local err = h.error or h.report_error
  local info = h.info or h.report_info

  start("remote-ssh: this machine")
  if vim.fn.has("nvim-0.11") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    err("Neovim 0.11 or newer is required", { "Upgrade Neovim." })
  end

  local ssh = require("remote-ssh.ssh")
  if vim.fn.executable(ssh.cmd()) == 1 then
    local out = vim.fn.system({ ssh.cmd(), "-V" })
    ok("OpenSSH client: " .. vim.trim(out))
    local major, minor = out:match("OpenSSH_(%d+)%.(%d+)")
    if major and (tonumber(major) < 8 or (tonumber(major) == 8 and tonumber(minor) < 4)) then
      warn("OpenSSH older than 8.4: password prompts inside Neovim need DISPLAY to be set", { "Upgrade OpenSSH, or use key-based authentication." })
    end
  else
    err(("'%s' not found"):format(ssh.cmd()), { "Install the OpenSSH client.", "Or set ssh.cmd in setup()." })
  end
  if vim.fn.has("win32") == 1 then
    err("Native Windows is not supported (its OpenSSH lacks connection sharing)", { "Use WSL." })
  end

  if vim.fn.executable(ssh.askpass_path) == 1 then
    ok("Prompt helper is executable")
  else
    err("Prompt helper is not executable: " .. ssh.askpass_path, { "chmod +x " .. ssh.askpass_path })
  end

  if pcall(require, "telescope") then
    ok("telescope.nvim found")
  else
    warn("telescope.nvim not found: pickers fall back to vim.ui.select and the quickfix list", { "Install nvim-telescope/telescope.nvim (and nvim-lua/plenary.nvim)." })
  end

  local lsp = require("remote-ssh.lsp")
  local names = lsp.server_names()
  if #names == 0 then
    warn("No language servers are enabled", { "Enable some with vim.lsp.enable({...}), or list them in lsp.servers." })
  else
    ok("Language servers considered for remote buffers: " .. table.concat(names, ", "))
    for _, name in ipairs(names) do
      local cfg = lsp.get_config(name)
      if not cfg then
        warn(("No configuration found for '%s'"):format(name), { "Install nvim-lspconfig or define vim.lsp.config('" .. name .. "', {...})." })
      elseif type(cfg.cmd) ~= "table" then
        warn(("'%s' has a function as cmd and cannot run remotely"):format(name), { ("Set lsp.configs.%s.cmd = { ... } in remote-ssh's setup."):format(name) })
      end
    end
  end

  local hosts = require("remote-ssh.ssh_config").hosts()
  info(("%d host(s) in the ssh config"):format(#hosts))

  start("remote-ssh: connections")
  local any = false
  for host, conn in pairs(require("remote-ssh.connection").conns) do
    any = true
    if conn.state == "connected" then
      local i = conn.info or {}
      ok(("%s: connected (%s %s, %s; agent nvim %s)"):format(host, i.os or "?", i.arch or "?", i.libc or "?", conn.agent.nvim))
      info(("  install directory: %s"):format(conn.agent.base))
      if i.rg == "none" then
        warn(("%s: ripgrep unavailable, searches use grep/find"):format(host), { ":RemoteSSH setup " .. host .. " retries the download." })
      end
      if not conn.agent.mason then
        warn(("%s: mason.nvim unavailable, language servers are not installed automatically"):format(host), { ":RemoteSSH setup " .. host .. " retries the download." })
      end
    elseif conn.last_error then
      err(("%s: %s"):format(host, require("remote-ssh.util").errmsg(conn.last_error)))
    else
      info(("%s: %s"):format(host, conn.state))
    end
  end
  if not any then
    info("No connections yet. Use :RemoteSSH connect <host>")
  end
end

return M
