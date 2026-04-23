describe("ctest.run", function()
  after_each(function()
    package.loaded["cmake-tools.test.ctest"] = nil
    package.loaded["cmake-tools.utils"] = nil
    package.loaded["cmake-tools.ctest_diagnostics"] = nil
  end)

  it("passes list args as individual ctest arguments", function()
    local captured_args
    local captured_callback
    package.loaded["cmake-tools.utils"] = {
      run = function(_, _, _, args, _, _, callback)
        captured_args = args
        captured_callback = callback
      end,
    }

    local callback = function() end
    local ctest = require("cmake-tools.test.ctest")
    ctest.run("ctest", {}, { env_script = "", cwd = vim.loop.cwd(), runner = {} }, {
      build_dir = "build/debug",
      args = { "-VV", "--output-on-failure" },
      callback = callback,
    })

    assert.are.same({ "--test-dir", "build/debug", "-VV", "--output-on-failure" }, captured_args)
    assert.equals(callback, captured_callback)
  end)

  it("installs failure quickfix hooks when ctest diagnostics are enabled", function()
    local captured_hooks
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_doctest.cpp")
    vim.fn.writefile({ "TEST_CASE()" }, test_file)

    package.loaded["cmake-tools.utils"] = {
      run = function(_, _, _, _, _, _, _, hooks)
        captured_hooks = hooks
      end,
    }

    local ctest = require("cmake-tools.test.ctest")
    ctest.run("ctest", {}, {
      env_script = "",
      cwd = root,
      runner = {},
      ctest_diagnostics = function()
        return {
          enabled = true,
          open_quickfix = false,
          title_prefix = "CTest failures: ",
        }
      end,
    }, {
      build_dir = "build/debug",
    })

    assert.is_function(captured_hooks.on_output)
    assert.is_function(captured_hooks.after_exit)

    captured_hooks.on_output({
      "1: tests/test_doctest.cpp:10: ERROR: CHECK( value ) is NOT correct!",
      "  values: CHECK( false )",
    })
    captured_hooks.after_exit(8)

    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("CTest failures: ctest --test-dir build/debug", qf.title)
    assert.equals(1, #qf.items)
    assert.equals(vim.fs.normalize(test_file), vim.api.nvim_buf_get_name(qf.items[1].bufnr))
    assert.equals(10, qf.items[1].lnum)
  end)

  it("joins split diagnostic table fragments before parsing", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_doctest.cpp")
    vim.fn.writefile({ "TEST_CASE()" }, test_file)

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    local capture = ctest_diagnostics.new_capture()

    ctest_diagnostics.capture(capture, { "1: tests/test_doctest.cpp:10: ER" })
    ctest_diagnostics.capture(capture, { "ROR: CHECK( value ) is NOT correct!", "" })
    ctest_diagnostics.capture(capture, { "  values: CHECK( false )" })
    ctest_diagnostics.capture(capture, { "" })

    local lines = ctest_diagnostics.finish(capture)
    assert.equals("  values: CHECK( false )", lines[2])

    local items = ctest_diagnostics.parse_failure_items(lines, root)
    assert.equals(1, #items)
    assert.equals(vim.fs.normalize(test_file), items[1].filename)
    assert.equals(10, items[1].lnum)
    assert.equals("ERROR: CHECK( value ) is NOT correct!", items[1].text)
  end)
end)
