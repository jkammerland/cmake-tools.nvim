local M = {}

local DEFAULT_TITLE_PREFIX = "CTest failures: "

local function strip_ansi(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end

  line = line:gsub("\27%[[0-9;?]*[%a]", ""):gsub("\27%][^\7]*\7", ""):gsub("\r", "")
  return line ~= "" and line or nil
end

local function normalize_output_entries(data)
  if type(data) == "string" then
    return { data }
  end
  if type(data) ~= "table" then
    return {}
  end

  local entries = {}
  for _, value in ipairs(data) do
    if type(value) == "string" then
      entries[#entries + 1] = value
    end
  end
  return entries
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

function M.parse_failure_items(lines, cwd)
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
    if resolved:sub(1, 1) == "/" or resolved:match("^%a:[/\\]") then
      resolved = vim.fs.normalize(vim.fn.fnamemodify(resolved, ":p"))
    elseif type(cwd) == "string" and cwd ~= "" then
      resolved = vim.fs.normalize(vim.fs.joinpath(cwd, resolved))
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

    items[#items + 1] = {
      valid = 1,
      filename = resolved,
      lnum = tonumber(lnum) or 1,
      col = tonumber(col) or 1,
      text = trimmed,
      type = "E",
    }
  end

  for _, raw_line in ipairs(lines) do
    local line = strip_ansi(raw_line)
    if line then
      line = line:gsub("^%s*%d+:%s*", "")
      local path, lnum, col, text = line:match("^([A-Za-z]:.-):(%d+):(%d+):%s*(.+)$")
      if not path then
        path, lnum, col, text = line:match("^(.-):(%d+):(%d+):%s*(.+)$")
      end
      if not path then
        path, lnum, text = line:match("^(.-)%((%d+)%)%s*:%s*(.+)$")
      end
      if not path then
        path, lnum, text = line:match("^([A-Za-z]:.-):(%d+):%s*(.+)$")
      end
      if not path then
        path, lnum, text = line:match("^(.-):(%d+):%s*(.+)$")
      end

      if path and lnum and text then
        local failure_text = text
        if
          failure_text == "Failure"
          or failure_text:match("^ERROR:%s+")
          or failure_text:match("^FAILED:%s*")
          or failure_text:match("^[Ff]atal error:%s*")
          or failure_text:match("^FATAL ERROR:%s*")
          or failure_text:match("^[Ee]rror:%s*")
        then
          add_item(path, lnum, col, failure_text)
        end
      end
    end
  end

  return items
end

local function current_quickfix_title()
  local ok, info = pcall(vim.fn.getqflist, { title = 0 })
  if not ok or type(info) ~= "table" then
    return nil
  end
  return type(info.title) == "string" and info.title or nil
end

function M.update_quickfix(items, title, failed, opts)
  opts = opts or {}
  if opts.quickfix == false then
    return
  end

  title = (type(title) == "string" and title ~= "") and title
    or ((opts.title_prefix or DEFAULT_TITLE_PREFIX) .. "ctest")

  if failed and #items > 0 then
    vim.fn.setqflist({}, " ", {
      title = title,
      items = items,
    })
    if opts.open_quickfix ~= false then
      pcall(vim.cmd, "belowright copen 10")
      pcall(vim.cmd, "wincmd p")
    end
    return
  end

  local title_prefix = opts.title_prefix or DEFAULT_TITLE_PREFIX
  if (current_quickfix_title() or ""):find("^" .. vim.pesc(title_prefix)) then
    vim.fn.setqflist({}, " ", { title = title, items = {} })
    pcall(vim.cmd, "cclose")
  end
end

function M.command_hooks(opts)
  opts = opts or {}
  if opts.enabled == false then
    return nil
  end

  local capture = M.new_capture()
  local title = opts.title

  return {
    on_output = function(out, err)
      M.capture(capture, out, err)
    end,
    after_exit = function(code)
      local items = M.parse_failure_items(M.finish(capture), opts.cwd)
      M.update_quickfix(items, title, code ~= 0, opts)
    end,
  }
end

return M
