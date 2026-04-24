local M = {}
local uv = vim.uv or vim.loop

local DEFAULT_TITLE_PREFIX = "CTest failures: "
local LAST_TEST_LOG = { "Testing", "Temporary", "LastTest.log" }

local SOURCE_EXTENSIONS = {
  c = true,
  cc = true,
  cpp = true,
  cxx = true,
  h = true,
  hh = true,
  hpp = true,
  hxx = true,
  ipp = true,
  ixx = true,
  cppm = true,
  cxxm = true,
}

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

local function strip_ctest_prefix(line)
  return line:gsub("^%s*%d+:%s*", "")
end

local function path_extension(path)
  if type(path) ~= "string" then
    return nil
  end
  return path:match("%.([%w_]+)$")
end

local function looks_like_source_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local ext = path_extension(path)
  return ext ~= nil and SOURCE_EXTENSIONS[ext:lower()] == true
end

local function path_exists(path)
  return type(path) == "string" and path ~= "" and uv.fs_stat(path) ~= nil
end

local function resolve_path(filename, cwd, build_dir)
  if type(filename) ~= "string" or filename == "" then
    return nil
  end

  if filename:sub(1, 1) == "/" or filename:match("^%a:[/\\]") then
    return vim.fs.normalize(vim.fn.fnamemodify(filename, ":p"))
  end

  local candidates = {}
  if type(cwd) == "string" and cwd ~= "" then
    candidates[#candidates + 1] = vim.fs.normalize(vim.fs.joinpath(cwd, filename))
  end
  if type(build_dir) == "string" and build_dir ~= "" then
    candidates[#candidates + 1] = vim.fs.normalize(vim.fs.joinpath(build_dir, filename))
  end

  for _, candidate in ipairs(candidates) do
    if path_exists(candidate) then
      return candidate
    end
  end
  return candidates[1] or filename
end

local function extract_source_location(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end

  local best
  for token in line:gmatch("%S+") do
    token = token:gsub("^[%(%[]+", ""):gsub("[%)%],;]+$", "")
    local path, lnum, col = token:match("^(.-):(%d+):(%d+)$")
    if not path then
      path, lnum = token:match("^(.-):(%d+)$")
      col = nil
    end
    if path and looks_like_source_path(path) then
      best = {
        filename = path,
        lnum = tonumber(lnum) or 1,
        col = tonumber(col) or 1,
      }
    end
  end
  return best
end

local function sanitizer_header(line)
  local kind, sanitizer, message = line:match("^==%d+==(%u+):%s+([%w]+Sanitizer):%s+(.+)$")
  if sanitizer then
    return ("%s: %s"):format(sanitizer, message), kind
  end

  kind, sanitizer, message = line:match("^(%u+):%s+([%w]+Sanitizer):%s+(.+)$")
  if sanitizer then
    return ("%s: %s"):format(sanitizer, message), kind
  end

  sanitizer, message = line:match("^SUMMARY:%s+([%w]+Sanitizer):%s+(.+)$")
  if sanitizer then
    return ("%s: %s"):format(sanitizer, message), "SUMMARY"
  end
  return nil, nil
end

local function leak_section_message(line, current_text)
  if type(current_text) ~= "string" or not current_text:match("^LeakSanitizer:") then
    return nil
  end
  local text = line:match("^(Direct leak .+)$") or line:match("^(Indirect leak .+)$")
  if text then
    return "LeakSanitizer: " .. text
  end
  return nil
end

local function frame_rank(frame, cwd, build_dir)
  local resolved = resolve_path(frame.filename, cwd, build_dir) or frame.filename
  local normalized_cwd = resolve_path(cwd, nil)

  local sep = package.config:sub(1, 1)
  if normalized_cwd and (resolved == normalized_cwd or resolved:sub(1, #normalized_cwd + 1) == normalized_cwd .. sep) then
    local rel = resolved == normalized_cwd and "" or resolved:sub(#normalized_cwd + 2)
    if rel:find("^_deps/") or rel:find("/_deps/") then
      return 30
    end
    if rel:find("^build/") or rel:find("/CMakeFiles/") or rel:match("%.gentest%.h$") then
      return 20
    end
    return 10
  end

  if resolved:find("/usr/include/", 1, true) then
    return 40
  end
  if resolved:match("^/usr/") or resolved:match("^/lib") then
    return 50
  end
  return 25
end

local function select_sanitizer_frame(frames, cwd, build_dir)
  local selected
  local selected_rank = math.huge
  for _, frame in ipairs(frames) do
    local rank = frame_rank(frame, cwd, build_dir)
    if rank < selected_rank then
      selected = frame
      selected_rank = rank
    end
  end
  return selected
end

local function is_failure_text(text)
  return text == "Failure"
    or text:match("^ERROR:%s+")
    or text:match("^FAILED:%s*")
    or text:match("^[Ff]atal error:%s*")
    or text:match("^FATAL ERROR:%s*")
    or text:match("^[Ee]rror:%s*")
    or text:match("^[Rr]untime error:%s*")
    or text:match("^[%w]+Sanitizer:%s*")
end

local function is_stack_continuation_boundary(line)
  return line == ""
    or line:match("^%s*#%d+")
    or line:match("^==%d+==")
    or line:match("^SUMMARY:")
    or line:match("^Objects leaked above:")
    or line:match("^Direct leak ")
    or line:match("^Indirect leak ")
    or line:match("^%s*Start%s+%d+:")
    or line:match("^%s*%d+/%d+%s+Test")
end

local function normalize_failure_lines(lines)
  local normalized = {}
  local pending_frame

  local function flush_frame()
    if pending_frame then
      normalized[#normalized + 1] = pending_frame
      pending_frame = nil
    end
  end

  for _, raw_line in ipairs(lines) do
    local line = strip_ansi(raw_line)
    if line then
      line = strip_ctest_prefix(line)
      if line:match("^%s*#%d+") then
        flush_frame()
        pending_frame = line
      elseif pending_frame and not extract_source_location(pending_frame) and not is_stack_continuation_boundary(line) then
        local joined_without_space = pending_frame .. line
        if extract_source_location(joined_without_space) then
          pending_frame = joined_without_space
        else
          pending_frame = pending_frame .. " " .. line
        end
      else
        flush_frame()
        normalized[#normalized + 1] = line
      end
    end
  end

  flush_frame()
  return normalized
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

function M.parse_failure_items(lines, cwd, build_dir)
  if type(lines) ~= "table" then
    return {}
  end

  local items = {}
  local seen = {}
  local report

  local function add_item(filename, lnum, col, text)
    if type(filename) ~= "string" or filename == "" then
      return
    end

    local resolved = resolve_path(filename, cwd, build_dir)
    if not resolved then
      return
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

  local function finish_report()
    if not report then
      return
    end
    local frame = select_sanitizer_frame(report.frames, cwd, build_dir)
    if frame then
      add_item(frame.filename, frame.lnum, frame.col, report.text)
    end
    report = nil
  end

  local function add_report_frame(frame)
    if report and frame then
      report.frames[#report.frames + 1] = frame
    end
  end

  for _, raw_line in ipairs(normalize_failure_lines(lines)) do
    local line = strip_ansi(raw_line)
    if line then
      line = strip_ctest_prefix(line)
      local header, header_kind = sanitizer_header(line)
      if header then
        if not (header_kind == "SUMMARY" and report) then
          finish_report()
          report = {
            text = header,
            frames = {},
          }
        end
      else
        local leak_message = leak_section_message(line, report and report.text or nil)
        if leak_message and report and #report.frames == 0 then
          report.text = leak_message
        end
      end

      if report then
        add_report_frame(extract_source_location(line))
      end

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
        if is_failure_text(failure_text) then
          add_item(path, lnum, col, failure_text)
        end
      end
    end
  end

  finish_report()
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

function M.last_test_log_path(build_dir)
  if type(build_dir) ~= "string" or build_dir == "" then
    return nil
  end

  local path = build_dir
  for _, part in ipairs(LAST_TEST_LOG) do
    path = vim.fs.joinpath(path, part)
  end
  return vim.fs.normalize(path)
end

function M.import_last_log(build_dir, cwd, opts)
  opts = opts or {}
  local path = M.last_test_log_path(build_dir)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil, ("CTest LastTest.log not found under %s"):format(build_dir or "<no build dir>")
  end

  local lines = vim.fn.readfile(path)
  local items = M.parse_failure_items(lines, cwd, build_dir)
  local title_prefix = opts.title_prefix or DEFAULT_TITLE_PREFIX
  local title = opts.title or (title_prefix .. "LastTest.log import")
  M.update_quickfix(items, title, #items > 0, opts)
  return items, path
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
      local items = M.parse_failure_items(M.finish(capture), opts.cwd, opts.build_dir)
      M.update_quickfix(items, title, code ~= 0 or #items > 0, opts)
    end,
  }
end

return M
