-- SQL filters/globals: their outputs, and how they differ between dialects.
local template = require("dbdash.template")
local dialect = require("dbdash.db.dialect")
local yaml = require("dbdash.yaml")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function render(src, vars, db, autoescape)
  local env = template.env(dialect.get(db or "sqlite"), autoescape)
  local out, err = template.render(src, vars or {}, { env = env })
  if err then
    return "ERR " .. err.kind .. ": " .. err.message
  end
  return out
end

local ctx = yaml.parse([[
name: "it's"
ids: [1, 2, 3]
depts: [IT, "O'Neil"]
empty: []
nothing: ~
n: 10
conds: {"age > 30": "'senior'", "age > 20": "'mid'"}
]])

T["filter and global outputs"] = function()
  local cases = {
    { "{{ name|sql_escape }}", "it''s" },
    { "{{ nothing|sql_escape }}", "NULL" },
    { "{{ n|sql_escape }}", "10" },
    { "{{ name|sql_quote }}", "'it''s'" },
    { "{{ nothing|sql_quote }}", "NULL" },
    { "{{ n|sql_quote }}", "10" },
    { "{{ ids|sql_in }}", "(1, 2, 3)" },
    { "{{ depts|sql_in }}", "('IT', 'O''Neil')" },
    { "{{ n|sql_limit }}", "10" },
    { "{{ '25'|sql_limit }}", "25" },
    { "[{{ nothing|sql_limit }}]", "[]" },
    { "{{ sql_case(conds, \"'junior'\") }}", "CASE WHEN age > 30 THEN 'senior' WHEN age > 20 THEN 'mid' ELSE 'junior' END" },
    { "{{ sql_case({}, 'x') }}", "x" },
    { "{{ sql_case({}) }}", "NULL" },
  }
  for _, c in ipairs(cases) do
    eq({ c[1], render(c[1], ctx) }, c)
  end
end

T["outputs that depend on the dialect"] = function()
  eq(render("{{ 'users'|sql_id }}", ctx, "sqlite"), '"users"')
  eq(render("{{ 'users'|sql_id }}", ctx, "mysql"), "`users`")
  eq(render("{{ 'dbo.users'|sql_id }}", ctx, "mssql"), "[dbo].[users]")
  eq(render("{{ empty|sql_in }}", ctx), "(NULL)")
  eq(render("{{ true|sql_quote }}", ctx, "postgres"), "TRUE")
  eq(render("{{ true|sql_quote }}", ctx, "mssql"), "1")
  eq(render("{{ 'a\\\\b'|sql_quote }}", ctx, "mysql"), "'a\\\\b'")
  eq(render("{{ 'a\\\\b'|sql_quote }}", ctx, "postgres"), "'a\\b'")
  eq(render("{{ name|sql_quote }}", ctx, "mongodb"), '"it\\u0027s"')
end

T["sql_concat per dialect"] = function()
  eq(render("{{ sql_concat('a', n, name) }}", ctx, "mysql"), "CONCAT('a', 10, 'it''s')")
  eq(render("{{ sql_concat('a', 'b') }}", ctx, "sqlite"), "('a' || 'b')")
  eq(render("{{ sql_concat() }}", ctx), "''")
end

T["validation errors"] = function()
  eq(render("{{ 'a b'|sql_id }}", ctx), "ERR value: Invalid SQL identifier: a b")
  eq(render("{{ 1|sql_id }}", ctx), "ERR value: SQL identifier must be a string")
  eq(render("{{ 0|sql_limit }}", ctx):find("must be positive") ~= nil, true)
  eq(render("{{ 'x'|sql_limit }}", ctx), "ERR value: Invalid LIMIT value: x")
end

T["autoescape renders dialect literals"] = function()
  local src = "WHERE name = {{ name }} AND id IN {{ ids }} AND x = {{ nothing }} AND n = {{ n }}"
  eq(render(src, ctx, "postgres", true), "WHERE name = 'it''s' AND id IN (1, 2, 3) AND x = NULL AND n = 10")
  eq(render("{{ 'col'|safe }} {{ ids|join(',')|safe }}", ctx, "postgres", true), "col 1,2,3")
  eq(render("{{ name }}", ctx, "postgres", false), "it's")
  -- SQL filter output is SQL: not quoted again
  eq(render("x IN {{ ids|sql_in }} AND y = {{ name|sql_quote }}", ctx, "postgres", true), "x IN (1, 2, 3) AND y = 'it''s'")
end

return T
