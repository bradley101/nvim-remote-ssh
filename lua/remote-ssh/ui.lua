-- Blocking prompts, overridable through config.ui.
local M = {}

local function cfg()
  return require("remote-ssh.config").get().ui
end

--- Run a blocking prompt with the connection progress window out of the way.
local function prompting(fn, ...)
  local progress, dialog = require("remote-ssh.progress"), require("remote-ssh.dialog")
  -- Keep the background dimmed across the hand-over between the two windows.
  local dimmed = dialog.available() and progress.visible()
  if dimmed then
    dialog.dim("prompt", true)
  end
  progress.suspend()
  local res = { pcall(fn, ...) }
  progress.resume()
  if dimmed then
    dialog.dim("prompt", false)
  end
  if not res[1] then
    error(res[2], 0)
  end
  return res[2]
end

--- Ask a multiple-choice question. Returns the 1-based index of the chosen
--- entry, or 0 when cancelled. opts.title names the dialog.
local function confirm(msg, choices, opts)
  if cfg().confirm then
    return cfg().confirm(msg, choices) or 0
  end
  local dialog = require("remote-ssh.dialog")
  if dialog.available() then
    return dialog.confirm(msg, choices, opts)
  end
  local labels = {}
  for i, c in ipairs(choices) do
    labels[i] = "&" .. c
  end
  local ok, res = pcall(vim.fn.confirm, msg, table.concat(labels, "\n"), 1, "Question")
  return ok and res or 0
end

function M.confirm(msg, choices, opts)
  return prompting(confirm, msg, choices, opts)
end

--- Yes/No helper.
function M.yes(msg)
  return M.confirm(msg, { "Yes", "No" }) == 1
end

local function input(prompt, default, opts)
  if cfg().input then
    return cfg().input(prompt, default)
  end
  local dialog = require("remote-ssh.dialog")
  if dialog.available() then
    return dialog.input(prompt, default, opts)
  end
  local ok, res = pcall(vim.fn.input, { prompt = prompt, default = default or "", cancelreturn = vim.NIL })
  if not ok or res == vim.NIL then
    return nil
  end
  return res
end

function M.input(prompt, default, opts)
  return prompting(input, prompt, default, opts)
end

local function secret(prompt, opts)
  if cfg().secret then
    return cfg().secret(prompt)
  end
  local dialog = require("remote-ssh.dialog")
  if dialog.available() then
    return dialog.secret(prompt, opts)
  end
  local ok, res = pcall(vim.fn.inputsecret, { prompt = prompt, cancelreturn = vim.NIL })
  if not ok or res == vim.NIL then
    return nil
  end
  return res
end

function M.secret(prompt, opts)
  return prompting(secret, prompt, opts)
end

return M
