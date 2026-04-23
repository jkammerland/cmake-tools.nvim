describe("ctest.run", function()
  after_each(function()
    package.loaded["cmake-tools.test.ctest"] = nil
    package.loaded["cmake-tools.utils"] = nil
  end)

  it("passes list args as individual ctest arguments", function()
    local captured_args
    package.loaded["cmake-tools.utils"] = {
      run = function(_, _, _, args)
        captured_args = args
      end,
    }

    local ctest = require("cmake-tools.test.ctest")
    ctest.run("ctest", {}, { env_script = "", cwd = vim.loop.cwd(), runner = {} }, {
      build_dir = "build/debug",
      args = { "-VV", "--output-on-failure" },
    })

    assert.are.same({ "--test-dir", "build/debug", "-VV", "--output-on-failure" }, captured_args)
  end)
end)
