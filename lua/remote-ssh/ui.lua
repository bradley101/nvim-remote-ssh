-- Blocking prompts, overridable through config.ui.
local M = {}

local function cfg()
  return require("remote-ssh.config").get().ui
end

--- Ask a multiple-choice question. Returns the 1-based index of the chosen
--- entry, or 0 when cancelled.
function M.confirm(msg, choices)
  if cfg().confirm then
    return cfg().confirm(msg, choices) or 0
  end
  local labels = {}
  for i, c in ipairs(choices) do
    labels[i] = "&" .. c
  end
  local ok, res = pcall(vim.fn.confirm, msg, table.concat(labels, "\n"), 1, "Question")
  return ok and res or 0
end

--- Yes/No helper.
function M.yes(msg)
  return M.confirm(msg, { "Yes", "No" }) == 1
end

function M.input(prompt, default)
  if cfg().input then
    return cfg().input(prompt, default)
  end
  local ok, res = pcall(vim.fn.input, { prompt = prompt, default = default or "", cancelreturn = vim.NIL })
  if not ok or res == vim.NIL then
    return nil
  end
  return res
end

function M.secret(prompt)
  if cfg().secret then
    return cfg().secret(prompt)
  end
  local ok, res = pcall(vim.fn.inputsecret, { prompt = prompt, cancelreturn = vim.NIL })
  if not ok or res == vim.NIL then
    return nil
  end
  return res
end

return M
