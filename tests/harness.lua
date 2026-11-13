-- Minimal test harness: `nvim --headless -u NONE -l tests/run.lua`-free; see
-- tests/run.sh. Tests are plain functions that may block with vim.wait.
local H = { results = {}, only = os.getenv("RSSH_TEST_ONLY") }

function H.test(name, fn)
  if H.only and not name:find(H.only, 1, true) then
    return
  end
  local ok, err = xpcall(fn, debug.traceback)
  H.results[#H.results + 1] = { name = name, ok = ok, err = err }
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. "\n")
  if not ok then
    io.stdout:write("     " .. tostring(err):gsub("\n", "\n     ") .. "\n")
  end
end

function H.eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error((msg or "values differ") .. "\n  expected: " .. vim.inspect(b) .. "\n  actual:   " .. vim.inspect(a), 2)
  end
end

function H.ok(v, msg)
  if not v then
    error(msg or "expected a truthy value", 2)
  end
end

function H.match(s, pat, msg)
  if type(s) ~= "string" or not s:find(pat) then
    error((msg or "no match") .. "\n  pattern: " .. pat .. "\n  actual:  " .. vim.inspect(s), 2)
  end
end

--- Block until fn() is truthy.
function H.wait(fn, timeout, what)
  local ok = vim.wait(timeout or 10000, fn, 10)
  if not ok then
    error("timed out waiting for " .. (what or "condition"), 2)
  end
end

function H.finish()
  local failed = 0
  for _, r in ipairs(H.results) do
    if not r.ok then
      failed = failed + 1
    end
  end
  io.stdout:write(("\n%d passed, %d failed\n"):format(#H.results - failed, failed))
  vim.cmd(failed == 0 and "qa!" or "cq")
end

return H
