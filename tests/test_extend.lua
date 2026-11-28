-- A driver and a chart type of the user's (ARCHITECTURE.md#extending): directories on the
-- runtimepath (example/extend/), found as the built-in ones are, with their own validators.
local sched = require("dbdash.dashboard")
local h = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("dbdash").setup({ dashboard = { pause_hidden = false } })
    end,
    post_case = function()
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

local EXAMPLE = "example/extend/extend.yaml"

---The error of `text` (a config written next to the example).
local function err_of(text)
  local f = vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), f)
  local cfg, err = require("dbdash.config").load(f)
  eq(cfg, nil)
  return assert(err).message
end

T["found on the runtimepath: the driver, the chart type, their validators"] = function()
  h.with_extend(function()
    eq(require("dbdash.db").driver("numbers").name, "numbers")
    eq(vim.tbl_contains(require("dbdash.render.registry").type_names(), "progress"), true)
    local names = vim.tbl_map(function(v)
      return v.name
    end, require("dbdash.config.validators").list())
    eq(
      { vim.tbl_contains(names, "db numbers"), vim.tbl_contains(names, "chart progress") },
      { true, true }
    )
  end)
  -- gone with the directory
  eq(vim.tbl_contains(require("dbdash.render.registry").type_names(), "progress"), false)
end

T["a dashboard of them runs and draws"] = function()
  h.with_extend(function()
    require("dbdash.view.dashboard").start(EXAMPLE, { no_show = true })
    local d = assert(sched.get(sched.normalize(EXAMPLE)))
    eq(
      vim.wait(5000, function()
        return d.panels[1].state.result ~= nil
      end, 10),
      true
    )
    local rs = assert(d.panels[1].state.result)
    eq({ rs.row_count, rs.rows[2][2] }, { 8, 14 }) -- n2 x step 7
    require("dbdash.view.dashboard").redraw(d)
    local text = table.concat(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false), "\n")
    eq(text:find("n8", 1, true) ~= nil and text:find("█", 1, true) ~= nil, true)
    eq(text:find("80%", 1, true) ~= nil, true) -- n8: 56 of 70
    sched.stop(d.path)
  end)
end

T["their validators check their parts, and say so"] = function()
  h.with_extend(function()
    local base = "database: { url: 'numbers://', options: { step: %s } }\n"
      .. "query: { sql: '3' }\nshow: { type: progress, label_column: label%s }\n"
    eq(
      err_of(base:format("0", ", value_column: value")):find(
        "[db numbers] step must be positive",
        1,
        true
      ) ~= nil,
      true
    )
    eq(
      err_of(base:format("1", ", value_column: value, max: -1")):find(
        "[chart progress] max must be a positive number",
        1,
        true
      ) ~= nil,
      true
    )
    eq(
      err_of(base:format("1", "")):find("[chart progress] missing required field", 1, true) ~= nil,
      true
    )
    -- and the driver's options as every driver's: one it does not read
    eq(
      err_of(base:format("1, nope: 1", ", value_column: value")):find("[db numbers]", 1, true)
        ~= nil,
      true
    )
  end)
end

return T
