describe("build diagnostics", function()
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
  end)
end)
