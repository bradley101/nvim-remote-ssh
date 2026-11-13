-- Telescope front-ends. Loaded only when telescope.nvim is installed.
local api = vim.api
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local sorters = require("telescope.sorters")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local P = require("remote-ssh.path")
local search = require("remote-ssh.search")
local log = require("remote-ssh.log")

local M = {}

local preview_ns = api.nvim_create_namespace("remote-ssh-preview")

--- Replace telescope's open actions (which assume local paths) with `open`.
local function on_select(prompt_bufnr, open)
  local function run(cmd)
    return function()
      local entry = action_state.get_selected_entry()
      actions.close(prompt_bufnr)
      if entry then
        open(entry, cmd)
      end
    end
  end
  actions.select_default:replace(run("edit"))
  actions.select_horizontal:replace(run("split"))
  actions.select_vertical:replace(run("vsplit"))
  actions.select_tab:replace(run("tabedit"))
end

local function highlight_preview(bufnr, ft)
  if not ft or ft == "" then
    return
  end
  local ok, putils = pcall(require, "telescope.previewers.utils")
  if ok then
    pcall(putils.highlighter, bufnr, ft)
  end
end

local function show_line(self, bufnr, lnum)
  if not lnum then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
  pcall(api.nvim_buf_add_highlight, bufnr, preview_ns, "TelescopePreviewLine", lnum - 1, 0, -1)
  local win = self.state.winid
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
    pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
    pcall(api.nvim_win_call, win, function()
      vim.cmd("normal! zz")
    end)
  end
end

--- Previews a remote file, fetched through the agent (first 256 KB).
local function remote_previewer(conn)
  return previewers.new_buffer_previewer({
    title = "Remote file",
    get_buffer_by_name = function(_, entry)
      return entry.rpath
    end,
    define_preview = function(self, entry)
      local bufnr = self.state.bufnr
      if vim.b[bufnr].rssh_loaded then
        return show_line(self, bufnr, entry.lnum)
      end
      conn:request("exec", { cmd = { "head", "-c", "262144", entry.rpath }, timeout = 10000 }, function(err, res)
        if not api.nvim_buf_is_valid(bufnr) then
          return
        end
        local lines
        if err or res.code ~= 0 then
          lines = { "(cannot preview: " .. vim.trim(err and (err.message or err.code) or res.stderr) .. ")" }
        elseif res.stdout:find("\0", 1, true) then
          lines = { "(binary file)" }
        else
          lines = vim.split(res.stdout, "\n", { plain = true })
        end
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.b[bufnr].rssh_loaded = true
        local ok, ft = pcall(vim.filetype.match, { filename = entry.rpath, buf = bufnr })
        highlight_preview(bufnr, ok and ft or nil)
        show_line(self, bufnr, entry.lnum)
      end)
    end,
  })
end

--- Choose an SSH host. opts.on_choice(host).
function M.hosts(opts)
  opts = opts or {}
  local hosts = require("remote-ssh.ssh_config").hosts()
  pickers
    .new(opts, {
      prompt_title = "SSH hosts (type a name not listed and press <CR> to use it)",
      finder = finders.new_table({ results = hosts }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          local typed = action_state.get_current_line()
          actions.close(prompt_bufnr)
          local host = entry and entry[1] or vim.trim(typed or "")
          if host ~= "" then
            (opts.on_choice or function(h)
              require("remote-ssh").open(h)
            end)(host)
          end
        end)
        return true
      end,
    })
    :find()
end

--- Recently opened remote workspaces.
function M.recent(opts)
  opts = opts or {}
  pickers
    .new(opts, {
      prompt_title = "Recent remote workspaces",
      finder = finders.new_table({
        results = require("remote-ssh.state").recent(),
        entry_maker = function(r)
          local text = r.host .. ":" .. r.path
          return { value = r, display = text, ordinal = text }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            require("remote-ssh").open(entry.value.host, entry.value.path)
          end
        end)
        return true
      end,
    })
    :find()
end

--- Find files in the remote workspace. opts.conn, opts.root.
function M.files(opts)
  local conn, root = opts.conn, opts.root
  search.files(conn, root, function(err, files, truncated)
    if err then
      return log.error("File search failed: " .. (err.message or err.code))
    end
    pickers
      .new(opts, {
        prompt_title = ("Files  %s:%s%s"):format(conn.host, root, truncated and "  (truncated)" or ""),
        finder = finders.new_table({
          results = files,
          entry_maker = function(rel)
            return { value = rel, display = rel, ordinal = rel, rpath = P.join(root, rel) }
          end,
        }),
        sorter = conf.file_sorter(opts),
        previewer = remote_previewer(conn),
        attach_mappings = function(prompt_bufnr)
          on_select(prompt_bufnr, function(entry, cmd)
            require("remote-ssh").edit(conn.host, entry.rpath, nil, nil, cmd)
          end)
          return true
        end,
      })
      :find()
  end)
end

--- Live text search in the remote workspace. opts.conn, opts.root.
function M.live_grep(opts)
  local conn, root = opts.conn, opts.root
  local current
  local finder = setmetatable({
    close = function()
      if current then
        current.cancel()
        current = nil
      end
    end,
  }, {
    __call = function(_, prompt, process_result, process_complete)
      if current then
        current.cancel()
        current = nil
      end
      if not prompt or #prompt < 2 then
        return process_complete()
      end
      current = search.grep(conn, root, prompt, {}, function(batch)
        for _, r in ipairs(batch) do
          local text = ("%s:%d:%d: %s"):format(r.file, r.lnum, r.col, vim.trim(r.text))
          if process_result({ value = r, display = text, ordinal = text, rpath = P.join(root, r.file), lnum = r.lnum, col = r.col }) then
            return
          end
        end
      end, function()
        process_complete()
      end)
    end,
  })
  pickers
    .new(opts, {
      prompt_title = ("Live grep  %s:%s"):format(conn.host, root),
      finder = finder,
      sorter = sorters.highlighter_only(opts),
      previewer = remote_previewer(conn),
      debounce = 200,
      attach_mappings = function(prompt_bufnr)
        on_select(prompt_bufnr, function(entry, cmd)
          require("remote-ssh").edit(conn.host, entry.rpath, entry.lnum, entry.col, cmd)
        end)
        return true
      end,
    })
    :find()
end

--- Symbols of a buffer. opts.bufnr, opts.symbols (from remote-ssh.symbols).
function M.symbols(opts)
  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local list = opts.symbols or require("remote-ssh.symbols").any(bufnr) or {}
  local source_win = api.nvim_get_current_win()
  local previewer = previewers.new_buffer_previewer({
    title = "Symbol",
    get_buffer_by_name = function()
      return "rssh-symbols-" .. bufnr
    end,
    define_preview = function(self, entry)
      local pbuf = self.state.bufnr
      if not vim.b[pbuf].rssh_loaded then
        api.nvim_buf_set_lines(pbuf, 0, -1, false, api.nvim_buf_get_lines(bufnr, 0, -1, false))
        vim.b[pbuf].rssh_loaded = true
        highlight_preview(pbuf, vim.bo[bufnr].filetype)
      end
      show_line(self, pbuf, entry.lnum)
    end,
  })
  pickers
    .new(opts, {
      prompt_title = "Symbols",
      finder = finders.new_table({
        results = list,
        entry_maker = function(s)
          return {
            value = s,
            display = ("%s%s  [%s]"):format(string.rep("  ", s.depth), s.name, s.kind),
            ordinal = s.name .. " " .. s.kind,
            lnum = s.lnum,
            col = s.col,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = previewer,
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and api.nvim_win_is_valid(source_win) then
            api.nvim_set_current_win(source_win)
            api.nvim_win_set_cursor(source_win, { entry.lnum, entry.col - 1 })
            vim.cmd("normal! zz")
          end
        end)
        return true
      end,
    })
    :find()
end

return M
