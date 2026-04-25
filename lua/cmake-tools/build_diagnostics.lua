local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("cmake-tools build")
local tracked_buffers = {}

local function path_exists(path)
  return type(path) == "string" and path ~= "" and uv.fs_stat(path) ~= nil
end

local function is_windows_path(path)
  return type(path) == "string" and path:match("^%a:[/\\]") ~= nil
end

local function absolute_path(path)
  return type(path) == "string" and path ~= "" and (path:sub(1, 1) == "/" or is_windows_path(path))
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function strip_ansi(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end

  line = line:gsub("\27%[[0-9;?]*[%a]", ""):gsub("\27%][^\7]*\7", ""):gsub("\r", "")
  return line ~= "" and line or nil
end

local function split_output_string(value)
  local entries = {}
  value = value:gsub("\r\n", "\n")
  local start = 1
  while true do
    local next_newline = value:find("\n", start, true)
    if not next_newline then
      entries[#entries + 1] = value:sub(start)
      break
    end
    entries[#entries + 1] = value:sub(start, next_newline - 1)
    start = next_newline + 1
  end
  return entries
end

local function normalize_output_entries(data)
  if type(data) == "string" then
    return split_output_string(data)
  end
  if type(data) ~= "table" then
    return {}
  end

  local entries = {}
  for _, value in ipairs(data) do
    if type(value) == "string" then
      vim.list_extend(entries, split_output_string(value))
    end
  end
  return entries
end

function M.namespace()
  return ns
end

function M.new_capture()
  return {
    lines = {},
    pending_stdout = nil,
    pending_stderr = nil,
  }
end

function M.capture(capture, out, err)
  if type(capture) ~= "table" then
    return
  end

  local function consume(data, pending_key)
    local entries = normalize_output_entries(data)
    if #entries == 0 then
      return
    end

    local original_len = #entries
    local has_trailing_boundary = entries[original_len] == ""
    local pending = capture[pending_key]
    if pending then
      entries[1] = pending .. entries[1]
      capture[pending_key] = nil
    end

    local last = entries[#entries]
    if has_trailing_boundary then
      if original_len > 1 or not pending then
        entries[original_len] = nil
      end
    elseif type(last) == "string" and last ~= "" then
      capture[pending_key] = last
      entries[#entries] = nil
    end

    for _, entry in ipairs(entries) do
      local line = strip_ansi(entry)
      if line then
        capture.lines[#capture.lines + 1] = line
      end
    end
  end

  consume(out, "pending_stdout")
  consume(err, "pending_stderr")
end

function M.finish(capture)
  if type(capture) ~= "table" then
    return {}
  end

  for _, key in ipairs({ "pending_stdout", "pending_stderr" }) do
    local line = strip_ansi(capture[key])
    if line then
      capture.lines[#capture.lines + 1] = line
    end
    capture[key] = nil
  end

  return vim.deepcopy(capture.lines)
end

function M.parse_build_quickfix_items(lines)
  if type(lines) ~= "table" then
    return {}
  end

  local items = {}
  local seen = {}

  local function add_item(filename, lnum, col, text)
    if type(filename) ~= "string" or filename == "" then
      return
    end

    local resolved = filename
    if absolute_path(resolved) then
      resolved = vim.fs.normalize(vim.fn.fnamemodify(resolved, ":p"))
    end

    local trimmed = vim.trim(type(text) == "string" and text or "")
    if trimmed == "" then
      return
    end

    local key = table.concat({ resolved, tostring(lnum), tostring(col or 1), trimmed }, ":")
    if seen[key] then
      return
    end
    seen[key] = true

    local item = {
      valid = 1,
      filename = resolved,
      lnum = tonumber(lnum) or 1,
      col = tonumber(col) or 1,
      text = trimmed,
    }

    if trimmed:match("^fatal error:") or trimmed:match("^error:") then
      item.type = "E"
    elseif trimmed:match("^warning:") then
      item.type = "W"
    elseif trimmed:match("^note:") or trimmed:match("^required from here$") then
      item.type = "I"
    end

    items[#items + 1] = item
  end

  for _, raw_line in ipairs(lines) do
    local line = strip_ansi(raw_line)
    if line then
      local path, lnum, col, text = line:match("^([A-Za-z]:.-):(%d+):(%d+):%s*(.+)$")
      if not path then
        path, lnum, col, text = line:match("^(.-):(%d+):(%d+):%s*(.+)$")
      end
      if not path then
        path, lnum, text = line:match("^([A-Za-z]:.-):(%d+):%s*(.+)$")
      end
      if not path then
        path, lnum, text = line:match("^(.-):(%d+):%s*(.+)$")
      end

      if path and lnum and text then
        add_item(path, lnum, col, text)
      end
    end
  end

  return items
end

local function raw_quickfix_item_path(item)
  if type(item) ~= "table" then
    return nil
  end

  if type(item.filename) == "string" and item.filename ~= "" then
    return item.filename
  end

  local bufnr = tonumber(item.bufnr)
  if bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if type(name) == "string" and name ~= "" then
      return name
    end
  end

  return nil
end

function M.resolve_build_output_path(path, repo_root, build_dir)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local candidates = {}
  local seen = {}
  local function push(candidate)
    local normalized = normalize_path(candidate)
    if normalized and not seen[normalized] then
      candidates[#candidates + 1] = normalized
      seen[normalized] = true
    end
  end

  if absolute_path(path) then
    push(path)

    if repo_root and build_dir then
      local sep = package.config:sub(1, 1)
      local prefix = repo_root .. sep
      if path:sub(1, #prefix) == prefix then
        local suffix = path:sub(#prefix + 1)
        push(vim.fs.joinpath(build_dir, suffix))
      end
    end
  else
    if build_dir then
      push(vim.fs.joinpath(build_dir, path))
    end
    if repo_root then
      push(vim.fs.joinpath(repo_root, path))
    end
    push(path)
  end

  for _, candidate in ipairs(candidates) do
    if path_exists(candidate) then
      return candidate
    end
  end

  return candidates[1]
end

function M.rewrite_build_quickfix_items(items, repo_root, build_dir)
  local rewritten = {}
  local changed = false

  for _, item in ipairs(items or {}) do
    local next_item = vim.deepcopy(item)
    if item.valid ~= 0 then
      local raw_path = raw_quickfix_item_path(item)
      local resolved = M.resolve_build_output_path(raw_path, repo_root, build_dir)
      if resolved then
        if normalize_path(raw_path) ~= resolved or next_item.bufnr ~= nil then
          changed = true
        end
        next_item.filename = resolved
        next_item.bufnr = nil
      end
    end
    rewritten[#rewritten + 1] = next_item
  end

  return rewritten, changed
end

local function diagnostic_severity(text)
  local trimmed = vim.trim(type(text) == "string" and text or "")
  if trimmed:match("^fatal error:") or trimmed:match("^error:") then
    return vim.diagnostic.severity.ERROR
  end
  if trimmed:match("^warning:") then
    return vim.diagnostic.severity.WARN
  end
  return nil
end

function M.build_diagnostics_from_items(items)
  local by_path = {}

  for _, item in ipairs(items or {}) do
    if item.valid ~= 0 and type(item.lnum) == "number" and item.lnum > 0 then
      local path = normalize_path(raw_quickfix_item_path(item))
      local severity = diagnostic_severity(item.text)
      if path and severity then
        by_path[path] = by_path[path] or {}
        by_path[path][#by_path[path] + 1] = {
          lnum = item.lnum - 1,
          end_lnum = (type(item.end_lnum) == "number" and item.end_lnum > 0) and (item.end_lnum - 1)
            or (item.lnum - 1),
          col = math.max((tonumber(item.col) or 1) - 1, 0),
          end_col = math.max(tonumber(item.end_col) or tonumber(item.col) or 1, tonumber(item.col) or 1),
          severity = severity,
          source = "cmake build",
          message = vim.trim(type(item.text) == "string" and item.text or ""),
        }
      end
    end
  end

  return by_path
end

function M.clear_diagnostics(repo_root)
  local key = repo_root or "__global__"
  for bufnr in pairs(tracked_buffers[key] or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.diagnostic.reset, ns, bufnr)
    end
  end
  tracked_buffers[key] = {}
end

function M.apply_diagnostics(items, repo_root, opts)
  opts = opts or {}
  M.clear_diagnostics(repo_root)
  if opts.diagnostics == false then
    return
  end

  local key = repo_root or "__global__"

  local tracked = {}
  for path, diags in pairs(M.build_diagnostics_from_items(items)) do
    local bufnr = vim.fn.bufadd(path)
    if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      if vim.fn.bufloaded(bufnr) == 0 then
        pcall(vim.fn.bufload, bufnr)
      end

      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.diagnostic.set(ns, bufnr, diags, {
          underline = true,
          virtual_text = false,
          signs = true,
          severity_sort = true,
          update_in_insert = false,
        })
        tracked[bufnr] = true
      end
    end
  end

  tracked_buffers[key] = tracked
end

local function replace_quickfix_items(items, title, idx)
  local ok = pcall(vim.fn.setqflist, {}, "r", {
    title = title,
    items = items,
    idx = idx,
  })
  if ok then
    return
  end

  vim.fn.setqflist({}, " ", {
    title = title,
    items = items,
  })
  if type(idx) == "number" and idx > 0 and idx <= #items then
    pcall(vim.fn.setqflist, {}, "a", { idx = idx })
  end
end

local function current_quickfix_title()
  local ok, info = pcall(vim.fn.getqflist, { title = 0 })
  if not ok or type(info) ~= "table" then
    return nil
  end
  return type(info.title) == "string" and info.title or nil
end

function M.clear_quickfix(title)
  if type(title) ~= "string" or title == "" then
    return false
  end
  if current_quickfix_title() ~= title then
    return false
  end

  vim.fn.setqflist({}, "r", { title = title, items = {} })
  pcall(vim.cmd, "cclose")
  return true
end

function M.update_quickfix(items, title, repo_root, build_dir, opts)
  opts = opts or {}
  local rewritten = M.rewrite_build_quickfix_items(items, repo_root, build_dir)
  if opts.quickfix ~= false then
    replace_quickfix_items(rewritten, title, 1)
    if opts.open_quickfix ~= false and #rewritten > 0 then
      pcall(vim.cmd, "belowright copen 10")
      pcall(vim.cmd, "wincmd p")
    end
  end
  M.apply_diagnostics(rewritten, repo_root, opts)
  return rewritten
end

function M.command_hooks(opts)
  opts = opts or {}
  if opts.enabled == false then
    return nil
  end

  local capture = M.new_capture()
  local title = opts.title or "cmake build"

  return {
    on_output = function(out, err)
      M.capture(capture, out, err)
    end,
    after_exit = function(code)
      local lines = M.finish(capture)
      local items = M.parse_build_quickfix_items(lines)
      if code == 0 then
        M.apply_diagnostics({}, opts.repo_root, opts)
        if opts.quickfix ~= false then
          M.clear_quickfix(title)
        end
      elseif #items > 0 then
        M.update_quickfix(items, title, opts.repo_root, opts.build_dir, opts)
      end
    end,
  }
end

return M
