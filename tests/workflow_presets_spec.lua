local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

describe("workflow presets", function()
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
end)
