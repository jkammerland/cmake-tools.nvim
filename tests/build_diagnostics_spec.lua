describe("build diagnostics", function()
  it("keeps table output entries as separate lines", function()
    local build_diagnostics = require("cmake-tools.build_diagnostics")
    local capture = build_diagnostics.new_capture()

    build_diagnostics.capture(capture, {
      "include/example.h:2:5: error: broken contract",
      "include/example.h:3:1: warning: check this",
    })

    local lines = build_diagnostics.finish(capture)
    assert.equals(2, #lines)
    assert.equals("include/example.h:2:5: error: broken contract", lines[1])
    assert.equals("include/example.h:3:1: warning: check this", lines[2])
  end)

  it("joins split table output fragments before parsing", function()
    local build_diagnostics = require("cmake-tools.build_diagnostics")
    local capture = build_diagnostics.new_capture()

    build_diagnostics.capture(capture, { "include/example.h:2:5: er" })
    build_diagnostics.capture(capture, { "ror: broken contract", "" })
    build_diagnostics.capture(capture, { "ninja progress" })
    build_diagnostics.capture(capture, { "" })

    local lines = build_diagnostics.finish(capture)
    assert.equals(2, #lines)
    assert.equals("include/example.h:2:5: error: broken contract", lines[1])
    assert.equals("ninja progress", lines[2])

    local items = build_diagnostics.parse_build_quickfix_items(lines)
    assert.equals(1, #items)
    assert.equals("E", items[1].type)
  end)

  it("splits embedded newline output chunks before parsing", function()
    local build_diagnostics = require("cmake-tools.build_diagnostics")
    local capture = build_diagnostics.new_capture()

    build_diagnostics.capture(capture, "include/example.h:2:5: error: broken contract\ninclude/example.h:3:1: warning: check this\n")

    local lines = build_diagnostics.finish(capture)
    assert.equals(2, #lines)
    assert.equals("include/example.h:2:5: error: broken contract", lines[1])
    assert.equals("include/example.h:3:1: warning: check this", lines[2])

    local items = build_diagnostics.parse_build_quickfix_items(lines)
    assert.equals(2, #items)
  end)

  it("parses compiler output and applies diagnostics to source buffers", function()
    local root = vim.fn.tempname()
    local include_dir = vim.fs.joinpath(root, "include")
    vim.fn.mkdir(include_dir, "p")
    local source = vim.fs.joinpath(include_dir, "example.h")
    vim.fn.writefile({ "one", "two", "three" }, source)

    local build_diagnostics = require("cmake-tools.build_diagnostics")
    local items = build_diagnostics.parse_build_quickfix_items({
      "include/example.h:2:5: error: broken contract",
      "include/example.h:3:1: warning: check this",
      "include/example.h:3:1: note: context only",
    })

    assert.equals(3, #items)
    assert.equals("E", items[1].type)
    assert.equals("W", items[2].type)
    assert.equals("I", items[3].type)

    local rewritten = build_diagnostics.update_quickfix(items, "cmake --build", root, nil, {
      open_quickfix = false,
    })

    assert.equals(vim.fs.normalize(source), rewritten[1].filename)

    local bufnr = vim.fn.bufnr(source)
    local diagnostics = vim.diagnostic.get(bufnr, {
      namespace = build_diagnostics.namespace(),
    })

    assert.equals(2, #diagnostics)
    assert.equals(1, diagnostics[1].lnum)
    assert.equals(4, diagnostics[1].col)
    assert.equals(vim.diagnostic.severity.ERROR, diagnostics[1].severity)

    build_diagnostics.apply_diagnostics({}, root)
    assert.equals(0, #vim.diagnostic.get(bufnr, { namespace = build_diagnostics.namespace() }))

    build_diagnostics.update_quickfix(items, "cmake --build", root, nil, {
      open_quickfix = false,
    })
    assert.equals(2, #vim.diagnostic.get(bufnr, { namespace = build_diagnostics.namespace() }))
    build_diagnostics.apply_diagnostics({}, root, { diagnostics = false })
    assert.equals(0, #vim.diagnostic.get(bufnr, { namespace = build_diagnostics.namespace() }))
  end)

  it("clears only owned build quickfix entries after a successful build", function()
    local root = vim.fn.tempname()
    local include_dir = vim.fs.joinpath(root, "include")
    vim.fn.mkdir(include_dir, "p")
    local source = vim.fs.joinpath(include_dir, "example.h")
    vim.fn.writefile({ "one", "two" }, source)

    local build_diagnostics = require("cmake-tools.build_diagnostics")
    vim.fn.setqflist({}, "r", {
      title = "cmake --build",
      items = { { filename = source, lnum = 2, col = 1, text = "error: stale" } },
    })

    local hooks = build_diagnostics.command_hooks({
      enabled = true,
      title = "cmake --build",
      repo_root = root,
      open_quickfix = false,
    })
    hooks.after_exit(0)

    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("cmake --build", qf.title)
    assert.equals(0, #qf.items)

    vim.fn.setqflist({}, "r", {
      title = "user quickfix",
      items = { { filename = source, lnum = 2, col = 1, text = "keep this" } },
    })
    hooks.after_exit(0)

    qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("user quickfix", qf.title)
    assert.equals(1, #qf.items)
  end)

  it("does not clear quickfix after a successful build when quickfix integration is disabled", function()
    local root = vim.fn.tempname()
    local include_dir = vim.fs.joinpath(root, "include")
    vim.fn.mkdir(include_dir, "p")
    local source = vim.fs.joinpath(include_dir, "example.h")
    vim.fn.writefile({ "one", "two" }, source)

    local build_diagnostics = require("cmake-tools.build_diagnostics")
    vim.fn.setqflist({}, "r", {
      title = "CMake build: cmake --build",
      items = { { filename = source, lnum = 2, col = 1, text = "keep this" } },
    })

    local hooks = build_diagnostics.command_hooks({
      enabled = true,
      quickfix = false,
      title = "CMake build: cmake --build",
      repo_root = root,
      open_quickfix = false,
    })
    hooks.after_exit(0)

    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("CMake build: cmake --build", qf.title)
    assert.equals(1, #qf.items)
  end)
end)
