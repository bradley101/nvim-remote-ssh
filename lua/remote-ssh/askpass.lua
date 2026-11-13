-- Receives prompts from bin/rssh-askpass (called by ssh) and asks the user.
local util = require("remote-ssh.util")
local ui = require("remote-ssh.ui")
local log = require("remote-ssh.log")

local M = {}

--- Optional override: function(prompt, kind) -> string|nil. Used by tests and
--- by users who want to plug in a password manager.
M.handler = nil

local function default_handler(prompt, kind)
  if kind == "confirm" or prompt:find("continue connecting", 1, true) then
    -- Host key confirmation: show the whole message (it contains the
    -- fingerprint) and require an explicit choice.
    local text = prompt:gsub("%s*%(yes/no[^)]*%)%??%s*$", "")
    local choice = ui.confirm(text .. "\n\nTrust this host and continue?", { "Yes", "No" })
    return choice == 1 and "yes" or "no"
  end
  if kind == "none" then
    -- Informational (e.g. "confirm user presence for key"): nothing to enter.
    log.info(prompt)
    return ""
  end
  return ui.secret((prompt:gsub("%s*$", " ")))
end

--- Called through `nvim --remote-expr`. Returns "RSSH_OK:<answer>" or
--- "RSSH_CANCEL".
function M.ask(hex, kind)
  local prompt = util.from_hex(hex or "")
  local ok, answer = pcall(M.handler or default_handler, prompt, kind ~= "" and kind or nil)
  if ok and answer ~= nil then
    -- ssh now carries on (checking the password, moving to the next hop),
    -- which can take a while: say so.
    pcall(require("remote-ssh.connection").answered, prompt)
  end
  if not ok then
    log.debug("askpass handler failed: " .. tostring(answer))
    return "RSSH_CANCEL"
  end
  if answer == nil then
    return "RSSH_CANCEL"
  end
  return "RSSH_OK:" .. answer
end

return M
