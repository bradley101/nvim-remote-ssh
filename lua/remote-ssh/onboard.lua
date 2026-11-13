-- First-connect onboarding: inspect the server, decide what is missing,
-- ask once, install. All functions here run inside util.async coroutines.
local util = require("remote-ssh.util")
local ssh = require("remote-ssh.ssh")
local config = require("remote-ssh.config")
local ui = require("remote-ssh.ui")
local log = require("remote-ssh.log")
local state = require("remote-ssh.state")

local await, shq = util.await, util.shq

local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

function M.remote_file(name)
  return read_file(root .. "/remote/" .. name)
end

local function vars(tbl)
  local lines = {}
  for k, v in pairs(tbl) do
    lines[#lines + 1] = k .. "=" .. shq(v)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Run the probe script; returns the key/value table.
function M.probe(host, dir)
  local script = vars({ RSSH_DIR = dir or "" }) .. M.remote_file("probe.sh")
  local res = await(function(cb)
    ssh.script(host, script, { timeout = 60000 }, cb)
  end)
  if not res.body then
    if res.code ~= 0 and res.stderr ~= "" and not res.stdout:find(ssh.BEGIN, 1, true) then
      error(ssh.classify(host, res.stderr, res))
    end
    error(util.err(
      "probe",
      ("Could not inspect '%s': the server did not run the setup script."):format(host),
      "A POSIX `sh` is required on the server.\n" .. util.tail(res.stderr ~= "" and res.stderr or res.stdout, 4)
    ))
  end
  local info = {}
  for line in res.body:gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then
      info[k] = v
    end
  end
  if res.noise and res.noise:match("%S") then
    log.debug("shell startup output on " .. host .. " (ignored): " .. util.tail(res.noise, 3))
  end
  return info
end

local OS = { Linux = "linux", Darwin = "macos" }
local ARCH = { x86_64 = "x86_64", amd64 = "x86_64", aarch64 = "arm64", arm64 = "arm64" }

local function expand(template, map)
  return (template:gsub("{(%w+)}", function(k)
    return map[k] or ""
  end))
end

--- Decide what the server needs. Returns a plan:
--- { nvim = path to use, items = {...to install...}, script_vars = {...} }
--- Throws a structured error when the server cannot be supported.
function M.plan(host, info)
  local cfg = config.get()
  local src = cfg.sources
  local os_name, arch = OS[info.os], ARCH[info.arch]
  local base = info.base
  local plan = { base = base, items = {}, vars = { BASE = base, ALLOW_UNVERIFIED = "0" } }

  -- Agent runtime.
  local sys_ok = cfg.remote.use_system_nvim and info.nvim_sys_path and util.version_ge(info.nvim_sys, cfg.remote.min_nvim)
  if info.nvim_own and util.version_ge(info.nvim_own, cfg.remote.min_nvim) then
    plan.nvim = base .. "/nvim/bin/nvim"
  elseif sys_ok then
    plan.nvim = info.nvim_sys_path
  else
    if not os_name then
      error(util.err(
        "unsupported",
        ("'%s' runs %s, which is not supported (Linux and macOS are)."):format(host, info.os ~= "" and info.os or "an unknown OS"),
        ("Installing Neovim %s+ on the server yourself makes it usable."):format(cfg.remote.min_nvim)
      ))
    end
    if not arch then
      error(util.err(
        "unsupported",
        ("'%s' has a %s CPU; there is no prebuilt Neovim for it."):format(host, info.arch),
        ("Install Neovim %s+ on the server with its package manager and reconnect."):format(cfg.remote.min_nvim)
      ))
    end
    if info.libc == "musl" then
      error(util.err(
        "unsupported",
        ("'%s' uses musl libc (e.g. Alpine); the prebuilt Neovim does not run there."):format(host),
        ("Install Neovim %s+ on the server (e.g. `apk add neovim`) and reconnect."):format(cfg.remote.min_nvim)
      ))
    end
    local asset = ("nvim-%s-%s.tar.gz"):format(os_name, arch)
    local map = { version = src.nvim.version, asset = asset }
    plan.vars.NVIM_ASSET = asset
    plan.vars.NVIM_URL = expand(src.nvim.url, map)
    plan.vars.NVIM_SUM_URL = src.nvim.checksums and expand(src.nvim.checksums, map) or ""
    plan.vars.NVIM_COMPAT_URL = (os_name == "linux" and src.nvim.compat_url) and expand(src.nvim.compat_url, map) or ""
    plan.nvim = base .. "/nvim/bin/nvim"
    plan.items[#plan.items + 1] = ("Neovim %s (runs the remote agent, ~15 MB)"):format(src.nvim.version)
    plan.needs_nvim = true
  end

  -- ripgrep (optional: search falls back to grep/find).
  local skip = state.host(host).skip or {}
  if src.ripgrep.enabled and info.rg == "none" and os_name and arch and not skip.rg then
    local target = ({
      ["linux-x86_64"] = "x86_64-unknown-linux-musl",
      ["linux-arm64"] = "aarch64-unknown-linux-gnu",
      ["macos-x86_64"] = "x86_64-apple-darwin",
      ["macos-arm64"] = "aarch64-apple-darwin",
    })[os_name .. "-" .. arch]
    local asset = ("ripgrep-%s-%s.tar.gz"):format(src.ripgrep.version, target)
    local map = { version = src.ripgrep.version, asset = asset }
    plan.vars.RG_ASSET = asset
    plan.vars.RG_URL = expand(src.ripgrep.url, map)
    plan.vars.RG_SUM_URL = src.ripgrep.checksums and expand(src.ripgrep.checksums, map) or ""
    plan.items[#plan.items + 1] = ("ripgrep %s (fast file search, ~2 MB)"):format(src.ripgrep.version)
  end

  -- mason.nvim (optional: installs language servers on demand).
  if cfg.lsp.enabled and cfg.lsp.auto_install and info.mason ~= "yes" and not skip.mason then
    plan.vars.MASON_URL = expand(src.mason.url, { version = src.mason.version })
    plan.items[#plan.items + 1] = ("mason.nvim %s (installs language servers on request, <1 MB)"):format(src.mason.version)
  end

  return plan
end

--- Things that must hold before anything can be downloaded. Returns nil or a
--- structured error; `err.kind == "dir"` means another directory may help.
function M.preflight(host, info, plan)
  local cfg = config.get()
  if #plan.items == 0 then
    if info.writable ~= "yes" then
      return util.err("dir", ("Cannot write to %s on '%s'."):format(info.base, host))
    end
    return nil
  end
  if info.writable ~= "yes" then
    return util.err("dir", ("Cannot write to %s on '%s'."):format(info.base, host))
  end
  local free = tonumber(info.free_kb)
  if free and free < cfg.remote.min_free_kb then
    return util.err("dir", ("Only %d MB free in %s on '%s' (%d MB needed)."):format(free / 1024, info.base, host, cfg.remote.min_free_kb / 1024))
  end
  local missing = {}
  if info.has_curl ~= "yes" and info.has_wget ~= "yes" then
    missing[#missing + 1] = "curl or wget"
  end
  if info.has_tar ~= "yes" then
    missing[#missing + 1] = "tar"
  end
  if info.has_gzip ~= "yes" then
    missing[#missing + 1] = "gzip"
  end
  if #missing > 0 then
    return util.err(
      "tools",
      ("First-time setup on '%s' needs %s, which the server does not have."):format(host, table.concat(missing, ", ")),
      "Install them with the server's package manager and reconnect."
    )
  end
  return nil
end

--- Can the server reach the download host? Only called when something has
--- to be downloaded.
function M.check_internet(host, info)
  local url = config.get().sources.connectivity_url
  local script = vars({ URL = url })
    .. [[
if command -v curl >/dev/null 2>&1; then
  if curl -fsSI --connect-timeout 8 --max-time 12 -o /dev/null "$URL" 2>/dev/null; then echo net=ok; else echo net=fail; fi
else
  if wget -q --spider --timeout=10 --tries=1 "$URL" 2>/dev/null; then echo net=ok; else echo net=fail; fi
fi
env | grep -i '^https_proxy=' | head -n 1 | sed 's/^[^=]*=/proxy=/'
]]
  local res = await(function(cb)
    ssh.script(host, script, { timeout = 40000 }, cb)
  end)
  if res.body and res.body:find("net=ok", 1, true) then
    return true
  end
  local proxy = res.body and res.body:match("proxy=([^\n]+)")
  error(util.err(
    "offline",
    ("Cannot log in to '%s' with remote-ssh: the server has no internet access, and first-time setup needs to download components (could not reach %s from the server)."):format(host, url),
    proxy and ("The server's https_proxy is set to " .. proxy .. "; check that it works.")
      or "If the server needs a proxy, set https_proxy in its shell profile, then reconnect."
  ))
end

local function describe(info)
  return ("%s %s"):format(info.os or "?", info.arch or "?")
end

--- Ask the user once before anything is downloaded.
function M.consent(host, info, plan)
  if not config.get().remote.confirm_install then
    return true
  end
  local lines = {
    ("First-time setup on '%s' (%s)."):format(host, describe(info)),
    "",
    "The following will be downloaded on the server into",
    "  " .. plan.base,
  }
  for _, item in ipairs(plan.items) do
    lines[#lines + 1] = "  - " .. item
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Nothing outside that directory is changed, and no root access is used."
  return ui.confirm(table.concat(lines, "\n"), { "Install", "Cancel" }) == 1
end

--- Run the installer. Returns nothing on success; throws a structured error.
function M.install(host, plan, on_progress)
  local allow = "0"
  while true do
    plan.vars.ALLOW_UNVERIFIED = allow
    local script = vars(plan.vars) .. M.remote_file("install.sh")
    local pending = ""
    local fail, warnings = nil, {}
    local done = false
    local function handle(line)
      local kind, rest = line:match("^RSSH_(%u+)%s*(.*)$")
      if kind == "PROGRESS" then
        on_progress(rest)
      elseif kind == "WARN" then
        warnings[#warnings + 1] = rest
      elseif kind == "ERROR" then
        local code, msg = rest:match("^(%S+)%s*(.*)$")
        fail = { code = code, message = msg }
      elseif kind == "DONE" then
        done = true
      end
    end
    local res = await(function(cb)
      ssh.script(host, script, {
        on_stdout = function(chunk)
          pending = pending .. chunk
          while true do
            local nl = pending:find("\n", 1, true)
            if not nl then
              break
            end
            local line = pending:sub(1, nl - 1)
            pending = pending:sub(nl + 1)
            vim.schedule(function()
              handle(line)
            end)
          end
        end,
      }, cb)
    end)
    -- Let scheduled line handlers run before we look at the outcome.
    await(function(cb)
      vim.schedule(cb)
    end)
    for _, w in ipairs(warnings) do
      log.warn(("[%s] %s"):format(host, w))
    end
    if done then
      return
    end
    if not fail then
      if res.code ~= 0 and res.stderr ~= "" and not res.stdout:find(ssh.BEGIN, 1, true) then
        error(ssh.classify(host, res.stderr, res))
      end
      error(util.err("install", ("Setup on '%s' stopped unexpectedly."):format(host), util.tail(res.stderr ~= "" and res.stderr or res.stdout, 5)))
    end

    if fail.code == "nosum" and allow == "0" then
      local ok = ui.confirm(
        ("No checksum is available to verify a download on '%s':\n  %s\n\nInstall it without verification?"):format(host, fail.message),
        { "Install unverified", "Cancel" }
      ) == 1
      if not ok then
        error(util.err("cancelled", "Setup cancelled."))
      end
      allow = "1"
    elseif fail.code == "download" then
      local again = ui.confirm(("Download failed on '%s':\n  %s"):format(host, fail.message), { "Retry", "Cancel" }) == 1
      if not again then
        error(util.err("install", ("Setup on '%s' failed: %s"):format(host, fail.message)))
      end
    elseif fail.code == "nowrite" or fail.code == "noexec" then
      error(util.err("dir", fail.message))
    elseif fail.code == "locked" then
      local again = ui.confirm(
        ("Another remote-ssh setup is already running on '%s'.\nWait for it to finish, then retry."):format(host),
        { "Retry", "Cancel" }
      ) == 1
      if not again then
        error(util.err("cancelled", "Setup cancelled."))
      end
    else
      error(util.err("install", ("Setup on '%s' failed: %s"):format(host, fail.message)))
    end
  end
end

--- Ask for a different install directory after `err` (kind "dir").
--- Returns the new directory or nil when the user gives up.
function M.ask_directory(host, err, current)
  local dir = ui.input(("%s\nInstall directory on '%s' (absolute path, empty to cancel): "):format(err.message, host), current)
  if not dir or util.trim(dir) == "" then
    return nil
  end
  dir = util.trim(dir)
  if dir:sub(1, 1) ~= "/" then
    log.warn("The install directory must be an absolute path.")
    return M.ask_directory(host, err, current)
  end
  dir = dir:gsub("/+$", "")
  if not dir:match("nvim%-remote%-ssh$") then
    dir = dir .. "/nvim-remote-ssh"
  end
  state.host(host).dir = dir
  state.save()
  return dir
end

return M
