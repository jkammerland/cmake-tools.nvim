local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

describe("workflow presets", function()
  after_each(function()
    package.loaded["cmake-tools"] = nil
    package.loaded["cmake-tools.utils"] = nil
    package.loaded["cmake-tools.const"] = nil
    vim.fn.setqflist({}, "r", { title = "", items = {} })
  end)

  it("lists and retrieves workflow presets", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    write_file(vim.fs.joinpath(root, "CMakePresets.json"), {
      "{",
      '  "version": 6,',
      '  "configurePresets": [{ "name": "debug", "binaryDir": "${sourceDir}/build/debug" }],',
      '  "buildPresets": [{ "name": "debug", "configurePreset": "debug" }],',
      '  "testPresets": [{ "name": "debug", "configurePreset": "debug" }],',
      '  "workflowPresets": [{',
      '    "name": "debug",',
      '    "displayName": "Debug Workflow",',
      '    "steps": [',
      '      { "type": "configure", "name": "debug" },',
      '      { "type": "build", "name": "debug" },',
      '      { "type": "test", "name": "debug" }',
      "    ]",
      "  }]",
      "}",
    })

    local Presets = require("cmake-tools.presets")
    local presets = Presets:parse(root)

    assert.are.same({ "debug" }, presets:get_workflow_preset_names())
    assert.equals("Debug Workflow", presets:get_workflow_preset("debug").displayName)
  end)

  it("parses sanitizer failures from workflow test output into quickfix", function()
    local root = vim.fn.tempname()
    local build_dir = vim.fs.joinpath(root, "build", "alusan")
    vim.fn.mkdir(vim.fs.joinpath(root, "tests"), "p")
    vim.fn.mkdir(vim.fs.joinpath(build_dir, "tests", "gentest", "tests"), "p")
    local test_file = vim.fs.joinpath(root, "tests", "test_coro.cpp")
    vim.fn.writefile({ "void test_coro() {}" }, test_file)
    write_file(vim.fs.joinpath(root, "CMakePresets.json"), {
      "{",
      '  "version": 6,',
      '  "configurePresets": [{ "name": "alusan", "binaryDir": "${sourceDir}/build/alusan" }],',
      '  "buildPresets": [{ "name": "alusan", "configurePreset": "alusan" }],',
      '  "testPresets": [{ "name": "alusan", "configurePreset": "alusan" }],',
      '  "workflowPresets": [{',
      '    "name": "alusan",',
      '    "steps": [',
      '      { "type": "configure", "name": "alusan" },',
      '      { "type": "build", "name": "alusan" },',
      '      { "type": "test", "name": "alusan" }',
      "    ]",
      "  }]",
      "}",
    })

    local const = require("cmake-tools.const")
    const.cmake_build_diagnostics.enabled = true
    const.cmake_build_diagnostics.open_quickfix = false
    const.ctest_diagnostics.enabled = true
    const.ctest_diagnostics.open_quickfix = false
    const.ctest_diagnostics.title_prefix = "CTest failures: "
    const.cmake_compile_commands_options.refresh_after_workflow = false

    local Result = require("cmake-tools.result")
    local captured_hooks
    package.loaded["cmake-tools.utils"] = {
      has_active_job = function()
        return false
      end,
      get_cmake_configuration = function()
        return Result:new(0)
      end,
      file_exists = function(path)
        return vim.uv.fs_stat(path) ~= nil
      end,
      mkdir = function(path)
        vim.fn.mkdir(path, "p")
      end,
      run = function(_, _, _, _, _, _, callback, hooks)
        captured_hooks = hooks
        hooks.on_output({
          "Test project " .. build_dir,
          "      Start  1: coro/repeat await timer",
          "1/1 Test  #1: coro/repeat await timer ................***Failed    0.07 sec",
          "==2980010==ERROR: LeakSanitizer: detected memory leaks",
          "Direct leak of 216 byte(s) in 1 object(s) allocated from:",
          "    #0 0x7f045b4e7a3b in operator new(unsigned long) (/lib64/libasan.so.8+0xe7a3b)",
          "    #1 0x0000003fa45f in timer_wheels::task<void> tests/gentest/tests/../../../../../tests/test_coro.cpp:132",
          "SUMMARY: AddressSanitizer: 216 byte(s) leaked in 1 allocation(s).",
        }, nil)
        hooks.after_exit(8)
        if callback then
          callback(Result:new_error(17, "workflow failed"))
        end
      end,
    }

    local previous_cwd = vim.loop.cwd()
    if previous_cwd then
      vim.opt.runtimepath:append(previous_cwd)
    end
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    local cmake = require("cmake-tools")
    cmake.run_workflow_preset({ args = "alusan", fargs = { "alusan" } }, function() end)
    if previous_cwd then
      vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
    end

    assert.is_table(captured_hooks)
    local qf = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("CTest failures: cmake --workflow --preset alusan", qf.title)
    assert.equals(1, #qf.items)
    assert.equals(vim.fs.normalize(test_file), vim.api.nvim_buf_get_name(qf.items[1].bufnr))
    assert.equals(132, qf.items[1].lnum)
    assert.equals("LeakSanitizer: Direct leak of 216 byte(s) in 1 object(s) allocated from:", qf.items[1].text)
  end)
end)
