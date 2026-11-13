-- Functions, methods, classes... of a buffer, read from its treesitter tree.
-- Works for any language with a parser installed, without per-language
-- queries: definitions are recognised by node type naming conventions that
-- tree-sitter grammars share.
local api = vim.api

local M = {}

-- { pattern on node type, kind }; first match wins.
local RULES = {
  { "^method", "Method" },
  { "^singleton_method$", "Method" },
  { "^constructor", "Constructor" },
  { "^function", "Function" },
  { "^func_", "Function" },
  { "^local_function", "Function" },
  { "^class", "Class" },
  { "^struct", "Struct" },
  { "^union", "Struct" },
  { "^interface", "Interface" },
  { "^trait", "Interface" },
  { "^protocol", "Interface" },
  { "^enum", "Enum" },
  { "^impl", "Impl" },
  { "^namespace", "Namespace" },
  { "^module", "Module" },
  { "^mod_", "Module" },
  { "^object_", "Class" },
  { "^type_alias", "Type" },
  { "^type_spec$", "Type" },
  { "^type_item$", "Type" },
  { "^type_definition$", "Type" },
  { "^macro_definition$", "Macro" },
  { "^preproc_function_def$", "Macro" },
}

local SUFFIXES = { "_definition", "_declaration", "_item", "_specifier", "_statement", "_spec", "_def" }
-- Grammars (e.g. Ruby) that name definition nodes with a bare word.
local BARE = { method = true, singleton_method = true, class = true, module = true }

local function classify(type)
  local definitionish = BARE[type] or false
  if not definitionish then
    for _, suffix in ipairs(SUFFIXES) do
      if type:sub(-#suffix) == suffix then
        definitionish = true
        break
      end
    end
  end
  if not definitionish then
    return nil
  end
  for _, rule in ipairs(RULES) do
    if type:find(rule[1]) then
      return rule[2]
    end
  end
  return nil
end

local function field(node, name)
  local list = node:field(name)
  return list and list[1] or nil
end

local function text_of(node, bufnr)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or not text then
    return nil
  end
  text = text:match("^[^\n]*")
  if #text > 80 then
    text = text:sub(1, 77) .. "..."
  end
  return text
end

--- The identifier naming a definition node, or nil for anonymous ones.
local function name_of(node, bufnr)
  local n = field(node, "name")
  if n then
    return text_of(n, bufnr)
  end
  -- C-family: the name hides inside nested declarators.
  local d = field(node, "declarator")
  local guard = 0
  while d and guard < 8 do
    guard = guard + 1
    local inner = field(d, "declarator") or field(d, "name")
    if not inner then
      if d:type():find("identifier") or d:type() == "operator_name" or d:type() == "destructor_name" then
        return text_of(d, bufnr)
      end
      return nil
    end
    if inner:type():find("identifier") or inner:type() == "operator_name" or inner:type() == "destructor_name" then
      return text_of(inner, bufnr)
    end
    d = inner
  end
  -- Rust `impl Type` / `impl Trait for Type`.
  local t = field(node, "type")
  if t and node:type():find("^impl") then
    local trait = field(node, "trait")
    return (trait and (text_of(trait, bufnr) .. " for ") or "") .. (text_of(t, bufnr) or "?")
  end
  return nil
end

--- `const f = () => {}` / `local f = function() end` style definitions.
local function assigned_function(node, bufnr)
  local type = node:type()
  if type == "variable_declarator" then
    local value = field(node, "value")
    if value and (value:type() == "arrow_function" or value:type():find("^function")) then
      local n = field(node, "name")
      return n and text_of(n, bufnr)
    end
  end
  return nil
end

--- Symbols of bufnr as a flat list in document order:
--- { name, kind, lnum, col, end_lnum, depth }. Returns nil, reason when the
--- buffer has no parser.
function M.get(bufnr)
  bufnr = bufnr == 0 and api.nvim_get_current_buf() or bufnr or api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil, ("no treesitter parser for filetype '%s'"):format(vim.bo[bufnr].filetype)
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return {}
  end
  local out = {}
  local function visit(node, depth)
    local type = node:type()
    local kind = classify(type)
    local name
    if kind then
      name = name_of(node, bufnr)
      -- `struct foo x;` mentions a type; only bodies define one.
      if type:sub(-10) == "_specifier" and not field(node, "body") then
        name = nil
      end
    else
      name = assigned_function(node, bufnr)
      kind = name and "Function" or nil
    end
    local child_depth = depth
    if kind and name then
      local srow, scol, erow = node:range()
      out[#out + 1] = { name = name, kind = kind, lnum = srow + 1, col = scol + 1, end_lnum = erow + 1, depth = depth }
      child_depth = depth + 1
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child, child_depth)
      end
    end
  end
  visit(trees[1]:root(), 0)
  return out
end

--- Fallback: symbols from an attached language server.
function M.from_lsp(bufnr)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 3000)
  if not responses then
    return nil
  end
  local out = {}
  local kinds = vim.lsp.protocol.SymbolKind
  local function add(list, depth)
    for _, s in ipairs(list or {}) do
      local range = s.selectionRange or s.range or (s.location and s.location.range)
      if range then
        out[#out + 1] = {
          name = s.name,
          kind = kinds[s.kind] or "Symbol",
          lnum = range.start.line + 1,
          col = range.start.character + 1,
          end_lnum = (s.range or range)["end"].line + 1,
          depth = depth,
        }
      end
      add(s.children, depth + 1)
    end
  end
  for _, r in pairs(responses) do
    if r.result then
      add(r.result, 0)
    end
  end
  table.sort(out, function(a, b)
    return a.lnum < b.lnum
  end)
  return #out > 0 and out or nil
end

--- Treesitter symbols, else language server symbols.
function M.any(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  local list, reason = M.get(bufnr)
  if not list then
    list = M.from_lsp(bufnr)
    if not list then
      return nil, reason .. " and no language server provided symbols"
    end
  end
  return list
end

-- ---------------------------------------------------------------------------
-- Outline window
-- ---------------------------------------------------------------------------
local outline = { buf = nil, source = nil, symbols = {} }

local function outline_render()
  if not outline.buf or not api.nvim_buf_is_valid(outline.buf) then
    return
  end
  local lines = {}
  local list = {}
  if outline.source and api.nvim_buf_is_valid(outline.source) then
    list = M.any(outline.source) or {}
  end
  outline.symbols = list
  for _, s in ipairs(list) do
    lines[#lines + 1] = ("%s%s  [%s]"):format(string.rep("  ", s.depth), s.name, s.kind)
  end
  if #lines == 0 then
    lines = { "(no symbols)" }
  end
  vim.bo[outline.buf].modifiable = true
  api.nvim_buf_set_lines(outline.buf, 0, -1, false, lines)
  vim.bo[outline.buf].modifiable = false
end

function M.outline()
  local source = api.nvim_get_current_buf()
  if outline.buf and api.nvim_buf_is_valid(outline.buf) and vim.fn.bufwinid(outline.buf) ~= -1 then
    if source == outline.buf then
      return api.nvim_win_close(0, true)
    end
    outline.source = source
    return outline_render()
  end
  outline.source = source
  outline.buf = api.nvim_create_buf(false, true)
  vim.bo[outline.buf].buftype = "nofile"
  vim.bo[outline.buf].bufhidden = "wipe"
  vim.bo[outline.buf].filetype = "remote-ssh-outline"
  vim.cmd("botright vertical 36split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, outline.buf)
  for opt, val in pairs({ number = false, relativenumber = false, wrap = false, winfixwidth = true, cursorline = true, signcolumn = "no" }) do
    vim.wo[win][opt] = val
  end
  local function jump()
    local s = outline.symbols[api.nvim_win_get_cursor(0)[1]]
    local target = outline.source and vim.fn.bufwinid(outline.source) or -1
    if s and target ~= -1 then
      api.nvim_set_current_win(target)
      api.nvim_win_set_cursor(target, { s.lnum, s.col - 1 })
      vim.cmd("normal! zz")
    end
  end
  vim.keymap.set("n", "<CR>", jump, { buffer = outline.buf, nowait = true })
  vim.keymap.set("n", "o", jump, { buffer = outline.buf, nowait = true })
  vim.keymap.set("n", "R", outline_render, { buffer = outline.buf, nowait = true })
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = outline.buf, nowait = true })
  local group = api.nvim_create_augroup("RemoteSSHOutline", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    callback = function(args)
      if not outline.buf or not api.nvim_buf_is_valid(outline.buf) or vim.fn.bufwinid(outline.buf) == -1 then
        return
      end
      if args.buf ~= outline.buf and vim.bo[args.buf].buftype ~= "nofile" and vim.bo[args.buf].buftype ~= "terminal" then
        outline.source = args.buf
        outline_render()
      end
    end,
  })
  outline_render()
  vim.cmd("wincmd p")
end

return M
