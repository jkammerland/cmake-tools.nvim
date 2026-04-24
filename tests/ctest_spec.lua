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

  it("parses sanitizer stack frames and resolves build-relative source paths", function()
    local root = vim.fn.tempname()
    local build_dir = vim.fs.joinpath(root, "build", "alusan")
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    vim.fn.mkdir(vim.fs.joinpath(build_dir, "tests", "gentest", "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_coro.cpp")
    vim.fn.writefile({ "void test() {}" }, test_file)

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    local items = ctest_diagnostics.parse_failure_items({
      "==2980010==ERROR: LeakSanitizer: detected memory leaks",
      "Direct leak of 216 byte(s) in 1 object(s) allocated from:",
      "    #0 0x7f045b4e7a3b in operator new(unsigned long) (/lib64/libasan.so.8+0xe7a3b)",
      "    #1 0x0000003fa45f in timer_wheels::task<void> coro::coro2<std::atomic<i",
      "nt>&>() tests/gentest/tests/../../../../../tests/test_coro.cpp:132:7",
      "    #2 0x00000046fb1d in gentest::runner::invoke_case_once _deps/gentest-src/src/runner_case_invoker.cpp:20",
      "SUMMARY: AddressSanitizer: 216 byte(s) leaked in tests/gentest/tests/../../../../../tests/test_coro.cpp:132",
    }, root, build_dir)

    assert.equals(1, #items)
    assert.equals(vim.fs.normalize(test_file), items[1].filename)
    assert.equals(132, items[1].lnum)
    assert.equals(7, items[1].col)
    assert.equals("LeakSanitizer: Direct leak of 216 byte(s) in 1 object(s) allocated from:", items[1].text)
  end)

  it("resolves relative build directories against the CTest cwd", function()
    local root = vim.fn.tempname()
    local build_dir = vim.fs.joinpath(root, "build", "alusan")
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    vim.fn.mkdir(vim.fs.joinpath(build_dir, "tests", "gentest", "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_coro.cpp")
    vim.fn.writefile({ "void test() {}" }, test_file)

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    local items = ctest_diagnostics.parse_failure_items({
      "==2980010==ERROR: LeakSanitizer: detected memory leaks",
      "Direct leak of 216 byte(s) in 1 object(s) allocated from:",
      "    #1 0x0000003fa45f in test tests/gentest/tests/../../../../../tests/test_coro.cpp:132",
    }, root, "build/alusan")

    assert.equals(1, #items)
    assert.equals(vim.fs.normalize(test_file), items[1].filename)
  end)

  it("parses UBSan runtime errors as CTest quickfix entries", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_ubsan.cpp")
    vim.fn.writefile({ "int main() {}", "int overflow = 0;" }, test_file)

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    local items = ctest_diagnostics.parse_failure_items({
      "tests/test_ubsan.cpp:2:5: runtime error: signed integer overflow",
    }, root)

    assert.equals(1, #items)
    assert.equals(vim.fs.normalize(test_file), items[1].filename)
    assert.equals(2, items[1].lnum)
    assert.equals("runtime error: signed integer overflow", items[1].text)
  end)

  it("does not duplicate UBSan runtime errors when a summary line repeats the location", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_ubsan.cpp")
    vim.fn.writefile({ "int main() {}", "int overflow = 0;" }, test_file)

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    local items = ctest_diagnostics.parse_failure_items({
      "tests/test_ubsan.cpp:2:5: runtime error: signed integer overflow",
      "SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior tests/test_ubsan.cpp:2:5",
    }, root)

    assert.equals(1, #items)
    assert.equals(vim.fs.normalize(test_file), items[1].filename)
    assert.equals(2, items[1].lnum)
  end)

  it("keeps parsed sanitizer diagnostics even when CTest exits successfully", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_ubsan.cpp")
    vim.fn.writefile({ "int main() {}", "int overflow = 0;" }, test_file)

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    local hooks = ctest_diagnostics.command_hooks({
      enabled = true,
      cwd = root,
      open_quickfix = false,
      title = "CTest failures: ctest --test-dir build/ubsan",
    })
    hooks.on_output({
      "tests/test_ubsan.cpp:2:5: runtime error: signed integer overflow",
      "",
    })
    hooks.after_exit(0)

    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("CTest failures: ctest --test-dir build/ubsan", qf.title)
    assert.equals(1, #qf.items)
    assert.equals(vim.fs.normalize(test_file), vim.api.nvim_buf_get_name(qf.items[1].bufnr))
    assert.equals(2, qf.items[1].lnum)
  end)

  it("imports LastTest.log only through the explicit import helper", function()
    local root = vim.fn.tempname()
    local build_dir = vim.fs.joinpath(root, "build", "debug")
    local relative_build_dir = "build/debug"
    local log_dir = vim.fs.joinpath(build_dir, "Testing", "Temporary")
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    vim.fn.mkdir(log_dir, "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_ubsan.cpp")
    vim.fn.writefile({ "int main() {}", "int overflow = 0;" }, test_file)
    vim.fn.writefile({
      "tests/test_ubsan.cpp:2:5: runtime error: signed integer overflow",
    }, vim.fs.joinpath(log_dir, "LastTest.log"))

    local ctest_diagnostics = require("cmake-tools.ctest_diagnostics")
    vim.fn.setqflist({}, "r", {
      title = "user quickfix",
      items = { { filename = test_file, lnum = 1, text = "keep user entry" } },
    })

    local hooks = ctest_diagnostics.command_hooks({
      enabled = true,
      cwd = root,
      build_dir = build_dir,
      open_quickfix = false,
      title_prefix = "CTest failures: ",
    })
    hooks.after_exit(8)

    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("user quickfix", qf.title)
    assert.equals(1, #qf.items)

    local items, path = ctest_diagnostics.import_last_log(relative_build_dir, root, {
      open_quickfix = false,
      title_prefix = "CTest failures: ",
    })

    assert.equals(vim.fs.joinpath(log_dir, "LastTest.log"), path)
    assert.equals(1, #items)
    qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("CTest failures: LastTest.log import", qf.title)
    assert.equals(1, #qf.items)
    assert.equals(vim.fs.normalize(test_file), vim.api.nvim_buf_get_name(qf.items[1].bufnr))
  end)
end)
