-- Lua in templates: {% lua %} ... {% endlua %} blocks.
local template = require("dbdash.template")
local async = require("dbdash.util.async")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function render(src, opts)
  opts = opts or {}
  return template.render(src, opts.vars or {}, { env = opts.env, source = "b.yaml", line_offset = opts.offset })
end

local function pg_env()
  return template.env(require("dbdash.db.dialect").get("postgres"), true)
end

T["a block outputs what it returns; nil outputs nothing"] = function()
  eq(render("a{% lua %} return 1 + 1 {% endlua %}b"), "a2b")
  eq(render("[{% lua %}local x = 1{% endlua %}]"), "[]")
  eq(render("{% lua %}return {1, 'x'}{% endlua %}"), "[1, 'x']")
  -- the newline after {% endlua %} goes (trim_blocks), like after other statements
  eq(render("{% lua %}return 'a'{% endlua %}\nb"), "ab")
end

T["Lua code is not template syntax"] = function()
  eq(render("{% lua %}local t = {{1}} return t[1][1] .. '{% raw %}'{% endlua %}"), "1{% raw %}")
end

T["vars: the template variables visible at the block, read-only"] = function()
  eq(render("{% set x = 5 %}{% for i in [1, 2] %}{% lua %}return vars.x * vars.i{% endlua %},{% endfor %}"), "5,10,")
  eq(
    render("{% macro m(a) %}{% lua %}return vars.a .. '!'{% endlua %}{% endmacro %}{{ m('hi') }}"),
    "hi!"
  )
  eq(render("{% set l = [1, none] %}{% lua %}return #vars.l .. tostring(vars.l[2]){% endlua %}"), "1nil")
  local _, err = render("{% lua %}vars.y = 1{% endlua %}")
  eq(err.message, "vars is read-only (vars.y)")
end

T["autoescape applies to returned values; dbdash.safe opts out"] = function()
  eq(render([[{% lua %}return "it's"{% endlua %} {% lua %}return dbdash.safe("x = 'y'"){% endlua %}]], { env = pg_env() }), "'it''s' x = 'y'")
  eq(render([[{% lua %}return "it's"{% endlua %}]]), "it's")
end

T["errors carry the config file and line"] = function()
  local _, err = render("x\n{% lua %}\nlocal a = nil\nreturn a.b\n{% endlua %}", { offset = 10 })
  eq({ err.source, err.line, err.message }, { "b.yaml", 14, "attempt to index local 'a' (a nil value)" })
  _, err = render("{% lua %}return 'oops{% endlua %}", { offset = 2 })
  eq({ err.line, err.message:find("^syntax error: unfinished string") ~= nil }, { 3, true })
  _, err = render("{% lua %}return 1")
  eq(err.message, "missing {% endlua %}")
  _, err = render("{% raw %}x")
  eq(err.message, "missing {% endraw %}")
  _, err = render("{% lua %}error('boom', 0){% endlua %}")
  eq(err.message, "boom")
end

---Render inside a task (as dashboards do); returns out, err.
local function render_in_task(src, env)
  local res
  async.run(function()
    return template.render(src, {}, { env = env, source = "b.yaml" })
  end, function(e, out, err)
    res = { out = out, err = err or e }
  end)
  vim.wait(5000, function()
    return res ~= nil
  end, 1)
  return res.out, res.err
end

T["dbdash helpers wait without blocking; the query timeout stops loops"] = function()
  local ticks = 0
  local timer = vim.uv.new_timer()
  timer:start(5, 5, function()
    ticks = ticks + 1
  end)
  local out = render_in_task("{% lua %}dbdash.sleep(100) return 'slept'{% endlua %}", {})
  timer:stop()
  timer:close()
  eq(out, "slept")
  eq(ticks >= 5, true) -- the loop kept running while the template waited
  local _, err = render_in_task("{% lua %}while true do end{% endlua %}", { timeout = 100 })
  eq(err.message, "script did not finish within 0.1s")
end

T["args and meta come from env.lua"] = function()
  local env = { lua = { args = { n = 3 }, meta = require("dbdash.metadata").for_lua({ os = "linux" }) } }
  eq(render("{% lua %}return args.n .. meta.os{% endlua %}", { env = env }), "3linux")
end

return T
