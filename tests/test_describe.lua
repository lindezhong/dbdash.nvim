-- Descriptions: the dashboard's `description` and a chart's `show.description` are templates
-- (args, meta, imports) shown as Markdown in a float by K / :DbDashDescribe; ⓘ marks them.
local sched = require("dbdash.dashboard")
local eq = MiniTest.expect.equality

local dir
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("dbdash").setup({ lua = { confirm = false } })
      vim.cmd("runtime plugin/dbdash.lua")
    end,
    post_case = function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          vim.api.nvim_win_close(w, true)
        end
      end
      vim.cmd("silent! only")
      for _, d in ipairs(sched.list()) do
        sched.stop(d.path)
      end
      require("dbdash").setup({})
    end,
  },
})

local function run(name, text)
  local path = dir .. "/" .. name .. ".yaml"
  vim.fn.writefile(vim.split(text, "\n"), path)
  require("dbdash.view.dashboard").start(path)
  local d = assert(sched.get(sched.normalize(path)), "dashboard did not start")
  vim.wait(10000, function()
    for _, p in ipairs(d.panels) do
      if not (p.rs or p.error) or p.running then
        return false
      end
    end
    return true
  end, 10)
  require("dbdash.view.dashboard").redraw(d)
  return d
end

---Run :DbDashDescribe with the cursor at `lnum` (in the dashboard window) and return the
---float's lines (nil when none opened).
local function describe(d, lnum, col)
  local win = vim.fn.bufwinid(d.buf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { lnum, col or 0 })
  vim.cmd("DbDashDescribe")
  vim.wait(5000, function()
    return vim.api.nvim_win_get_config(0).relative ~= ""
  end, 10)
  if vim.api.nvim_win_get_config(0).relative == "" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return lines, vim.api.nvim_get_current_win()
end

local GRID = [[
title: Sales
description: |
  # Sales overview
  Last **{{ args.hours }} hours**{% if meta.db_type %} from {{ meta.db_type }}{% endif %}.
database: { url: "sqlite:///:memory:" }
args: [{ name: hours, type: int, default: 24 }]
style: { dashboard: { grid-template-columns: 2 } }
panels:
  - query: { sql: SELECT 1 AS x }
    show:
      title: Visits
      description: |
        Panel {{ meta.panel_index }} ({{ meta.chart_type }}), {{ args.hours }}h, `{{ meta.db_type }}`.
  - database: { url: "lua://" }
    query: { sql: "return { { y = 2 } }" }
    show: { title: Plain }
]]

T["ⓘ marks only what has a description"] = function()
  local d = run("grid", GRID)
  local lines = vim.api.nvim_buf_get_lines(d.buf, 0, 3, false)
  eq(lines[1], "Sales ⓘ")
  eq(lines[3]:match("^Visits ⓘ%s+Plain$") ~= nil, true)
  local plain =
    run("plain", "database: { url: 'sqlite:///:memory:' }\nquery: { sql: SELECT 1 AS x }\n")
  eq(table.concat(vim.api.nvim_buf_get_lines(plain.buf, 0, -1, false), "\n"):find("ⓘ"), nil)
end

T["K on the header shows the dashboard's, on a panel the panel's, rendered as Markdown"] = function()
  local d = run("grid", GRID)
  local lines, win = describe(d, 1)
  eq(lines, { "# Sales overview", "Last **24 hours** from sqlite." })
  local buf = vim.api.nvim_win_get_buf(win)
  eq(
    { vim.bo[buf].filetype, vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].conceallevel },
    { "markdown", true, true, 2 }
  )
  -- With the markdown parser, treesitter must highlight the float; without it (some
  -- Windows installs) the markdown syntax does, and no filetype plugin error is printed.
  -- language.add returns nil (it does not throw) when there is no parser.
  local ok, has_parser = pcall(vim.treesitter.language.add, "markdown")
  if ok and has_parser then
    eq({ vim.treesitter.highlighter.active[buf] ~= nil, vim.bo[buf].syntax }, { true, "" })
  else
    eq({ vim.treesitter.highlighter.active[buf] ~= nil, vim.bo[buf].syntax }, { false, "markdown" })
    eq(vim.v.errmsg:find("Parser could not be created", 1, true), nil)
  end
  vim.cmd("close")
  lines = describe(d, 4)
  eq(lines, { "Panel 1 (table), 24h, `sqlite`." })
  vim.cmd("close")
  -- The panel without one: a warning, no float.
  local notes = {}
  local real = vim.notify
  vim.notify = function(m)
    notes[#notes + 1] = m
  end
  local title_line = vim.api.nvim_buf_get_lines(d.buf, 2, 3, false)[1]
  eq(describe(d, 3, title_line:find("Plain") - 1), nil)
  vim.notify = real
  eq(notes, { "dbdash: no description" })
end

T["one chart: both descriptions in one float; the keys come from setup()"] = function()
  require("dbdash").setup({ lua = { confirm = false }, dashboard = { keys = { describe = "gK" } } })
  local d = run(
    "one",
    [[
title: Board
description: About the board.
database: { url: "sqlite:///:memory:" }
query: { sql: SELECT 1 AS x }
show: { title: Chart, description: "About **{{ meta.panel_title }}**." }
]]
  )
  eq(vim.api.nvim_buf_get_lines(d.buf, 0, 1, false)[1], "Board ⓘ")
  eq(vim.fn.maparg("gK", "n", false, true).buffer, 1)
  eq(vim.fn.maparg("K", "n", false, true).buffer, nil)
  local lines = describe(d, 3)
  eq(lines, { "## Board", "", "About the board.", "", "## Chart", "", "About **Chart**." })
end

T["descriptions: imports, errors with their line, trust for Lua"] = function()
  vim.fn.writefile({ "{% macro who() %}team {{ args.team }}{% endmacro %}" }, dir .. "/m.md")
  local d = run(
    "imp",
    [[
database: { url: "sqlite:///:memory:" }
args: [{ name: team, default: data }]
description: |
  {% import 'm.md' as m %}Owned by {{ m.who() }}.
query: { sql: SELECT 1 AS x }
]]
  )
  eq(describe(d, 3), { "Owned by team data." })
  vim.cmd("close")
  local bad = run(
    "bad",
    "database: { url: 'sqlite:///:memory:' }\nquery: { sql: SELECT 1 AS x }\nshow:\n  description: |\n    {{ nope }}\n"
  )
  local msgs = {}
  local real = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  describe(bad, 3)
  vim.notify = real
  eq(table.concat(msgs, "\n"):find("bad%.yaml:5") ~= nil, true)
  -- A {% lua %} block in a description makes the config need trust.
  local path = dir .. "/lua.yaml"
  vim.fn.writefile({
    "database: { url: 'sqlite:///:memory:' }",
    "query: { sql: x }",
    "description: '{% lua %}x = 1{% endlua %}'",
  }, path)
  local cfg = assert(require("dbdash.config").load(path))
  eq(select(2, require("dbdash.trust").collect(path, cfg)), true)
end

T["floats work without treesitter parsers (filetype plugins would fail)"] = function()
  -- Some Neovim installs (seen on Windows) have no parser for lua or markdown: the
  -- built-in ftplugins then fail in vim.treesitter.start(), printing an error.
  local real_start, real_add = vim.treesitter.start, vim.treesitter.language.add
  vim.treesitter.start = function()
    error("Parser could not be created")
  end
  vim.treesitter.language.add = function(lang)
    return nil, ("No parser for language %q"):format(lang)
  end
  vim.v.errmsg = ""
  local ok, e = pcall(function()
    local popup = require("dbdash.view.popup")
    local win, buf = popup.open({ "local x = 1" }, { filetype = "lua" })
    eq({ vim.bo[buf].filetype, vim.bo[buf].syntax }, { "lua", "lua" })
    vim.api.nvim_win_close(win, true)
    win, buf = popup.open({ "# Title", "**bold**" }, { markdown = true })
    eq({ vim.bo[buf].filetype, vim.bo[buf].syntax }, { "markdown", "markdown" })
    vim.api.nvim_win_close(win, true)
  end)
  vim.treesitter.start, vim.treesitter.language.add = real_start, real_add
  assert(ok, e)
  eq(vim.v.errmsg, "") -- no filetype plugin ran into the missing parser
end

T["descriptions cannot assign arguments"] = function()
  local d = run(
    "assign",
    [[
database: { url: "sqlite:///:memory:" }
args: [{ name: n, type: int, default: 1 }]
description: "{% lua %}args.n = 5{% endlua %}x"
query: { sql: SELECT 1 AS x }
show: { title: Chart, description: "{% set args.n = 6 %}y" }
]]
  )
  local errs = {}
  d:describe_async(function(e)
    errs[#errs + 1] = e
  end)
  d.panels[1]:describe_async(function(e)
    errs[#errs + 1] = e
  end)
  vim.wait(3000, function()
    return #errs == 2
  end, 10)
  for _, e in ipairs(errs) do
    eq(
      sched.format_error(e):find("arguments cannot be assigned in a description", 1, true) ~= nil,
      true
    )
  end
  local a = require("dbdash.args")
  eq(a.value(a.find(d.cfg.args, "n"), d.state), 1)
end

return T
