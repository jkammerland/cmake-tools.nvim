local stub_notification
local stub_executor
local stub_runner
local original_notify

local function clear_modules()
  package.loaded["cmake-tools.utils"] = nil
  package.loaded["cmake-tools.notification"] = nil
  package.loaded["cmake-tools.runners"] = nil
  package.loaded["cmake-tools.executors"] = nil
end

describe("utils.run", function()
  before_each(function()
    clear_modules()

    stub_notification = {
      enabled = true,
      stop_calls = 0,
      start_calls = 0,
      notify_calls = {},
      notify = function(self, msg, level, opts)
        table.insert(self.notify_calls, { msg = msg, level = level, opts = opts })
      end,
      startSpinner = function(self)
        self.start_calls = self.start_calls + 1
      end,
      stopSpinner = function(self)
        self.stop_calls = self.stop_calls + 1
      end,
    }

    package.loaded["cmake-tools.notification"] = {
      new = function(_)
        return stub_notification
      end,
    }

    stub_runner = {
      run = function(_, _, _, _, _, _, on_exit, on_output)
        on_output("[ 50%] Running test", nil)
        on_exit(0)
      end,
    }
    stub_executor = {
      run = function(_, _, _, _, _, _, on_exit, on_output)
        on_output("[ 75%] Building", nil)
        on_exit(0)
      end,
    }

    package.loaded["cmake-tools.runners"] = {
      fake = stub_runner,
    }

    package.loaded["cmake-tools.executors"] = {
      fake = stub_executor,
    }
    original_notify = vim.notify
  end)

  after_each(function()
    vim.notify = original_notify
    clear_modules()
  end)

  it("stops spinner when run completes", function()
    local utils = require("cmake-tools.utils")

    utils.run("ctest", "", {}, {}, vim.loop.cwd(), { name = "fake", opts = {} }, nil)

    assert.equals(1, stub_notification.start_calls)
    assert.equals(1, stub_notification.stop_calls)
  end)

  it("handles table output from terminal adapters", function()
    local utils = require("cmake-tools.utils")

    stub_runner.run = function(_, _, _, _, _, _, on_exit, on_output)
      on_output({ "[ 25%] Building", "" }, nil)
      on_exit(0)
    end

    utils.run("cmake", "", {}, {}, vim.loop.cwd(), { name = "fake", opts = {} }, nil)

    assert.equals(1, stub_notification.start_calls)
    assert.equals("[ 25%] Building", stub_notification.notify_calls[2].msg)
  end)

  it("calls optional output and exit hooks", function()
    local utils = require("cmake-tools.utils")
    local output = {}
    local exits = {}

    utils.run("ctest", "", {}, {}, vim.loop.cwd(), { name = "fake", opts = {} }, nil, {
      on_output = function(out, err)
        table.insert(output, { out = out, err = err })
      end,
      after_exit = function(code)
        table.insert(exits, code)
      end,
    })

    assert.equals("[ 50%] Running test", output[1].out)
    assert.equals(0, exits[1])
  end)

  it("allows a custom save hook to prevent execution", function()
    local utils = require("cmake-tools.utils")
    local did_run = false
    local notify_message
    local save_context
    local result

    vim.notify = function(msg)
      notify_message = msg
    end
    stub_runner.run = function()
      did_run = true
    end
    utils.set_save_before_run(function(context)
      save_context = context
      return false, "project save failed"
    end)

    utils.run("ctest", "", {}, { "--test-dir", "build" }, "/tmp/project", { name = "fake", opts = {} }, function(next_result)
      result = next_result
    end)

    assert.False(did_run)
    assert.equals("runner", save_context.kind)
    assert.equals("/tmp/project", save_context.cwd)
    assert.equals("project save failed", notify_message)
    assert.equals("project save failed", result.message)
  end)

  it("uses the save hook before execute", function()
    local utils = require("cmake-tools.utils")
    local did_execute = false
    local result

    vim.notify = function() end
    stub_executor.run = function()
      did_execute = true
    end
    utils.set_save_before_run(function(context)
      assert.equals("executor", context.kind)
      return false, "cannot write buffer"
    end)

    utils.execute("cmake", "", {}, { "--build", "build" }, "/tmp/project", { name = "fake", opts = {} }, function(next_result)
      result = next_result
    end)

    assert.False(did_execute)
    assert.equals("cannot write buffer", result.message)
  end)

  it("preserves runner failure messages", function()
    local utils = require("cmake-tools.utils")
    local result

    stub_runner.run = function(_, _, _, _, _, _, on_exit)
      on_exit(8)
    end

    utils.run("ctest", "", {}, {}, vim.loop.cwd(), { name = "fake", opts = {} }, function(next_result)
      result = next_result
    end)

    assert.equals("Process exited with code 8", result.message)
  end)
end)
