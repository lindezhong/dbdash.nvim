-- Engine behavior not covered by the Jinja comparison cases.
local template = require("dbdash.template")
local R = template.runtime
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function err_of(src, vars, opts)
  local out, err = template.render(src, vars or {}, opts)
  eq(out, nil)
  return err
end

T["python float repr"] = function()
  local cases = {
    [0.1] = "0.1",
    [1.5] = "1.5",
    [1e-05] = "1e-05",
    [0.0001] = "0.0001",
    [1e16] = "1e+16",
    [123456789.125] = "123456789.125",
    [-2.5e-10] = "-2.5e-10",
    [42] = "42",
    [-7] = "-7",
    [1 / 3] = "0.3333333333333333",
  }
  for v, want in pairs(cases) do
    eq({ v, R.numstr(v) }, { v, want })
  end
end

T["error line maps to the YAML file with line_offset"] = function()
  local e = err_of("SELECT\n  {{ missing }}", {}, { source = "cfg.yaml", line_offset = 9 })
  eq({ e.kind, e.line, e.source }, { "undefined", 11, "cfg.yaml" })
  eq(tostring(e), "cfg.yaml:11: 'missing' is undefined")
end

T["syntax errors carry a column"] = function()
  local e = err_of("ab\n  {{ 1 + }}")
  eq({ e.kind, e.line, e.col }, { "syntax", 2, 10 })
end

T["unsupported constructs are explained"] = function()
  local cases = {
    ["{% include 'x' %}"] = "'include' is not supported",
    ["{% extends 'x' %}"] = "'extends' is not supported",
    ["{% for i in [1] if i %}{% endfor %}"] = "loop filtering",
    ["{% set x %}y{% endset %}"] = "block set",
    ["{{ [1, 2][0:1] }}"] = "slices are not supported",
    ["{{ 'a'.replace('a', 'b') }}"] = "calling '.replace()' is not supported",
    ["{{ x is odd }}"] = "No test named 'odd'",
    ["{% for i in [1] %}{{ loop.cycle('a') }}{% endfor %}"] = "calling '.cycle()' is not supported",
    ["{{ '%s' % 1 }}"] = "string formatting",
    ["{{ f(*a) }}"] = "*args",
  }
  for src, want in pairs(cases) do
    local e = err_of(src, { x = 1 })
    eq({ src, e.message:find(want, 1, true) ~= nil }, { src, true })
  end
end

T["compiled templates are cached by source"] = function()
  local a = template.compile("{{ x }}")
  eq(template.compile("{{ x }}") == a, true)
  eq(a:render({ x = 1 }), "1")
  eq(a:render({ x = "y" }), "y")
end

T["context values from YAML keep their types"] = function()
  local yaml = require("dbdash.yaml")
  local ctx = yaml.parse("depts: [IT, HR]\nfilters: {region: Asia}\nnone_val: ~\n")
  eq(template.render("{{ depts|join(',') }} {{ filters.region }} {{ none_val }}", ctx), "IT,HR Asia None")
end

T["autoescape hook formats output values"] = function()
  local env = {
    autoescape = true,
    escape = function(v)
      return type(v) == "string" and ("'" .. v:gsub("'", "''") .. "'") or R.str(v)
    end,
  }
  local out = template.render("{{ s }} {{ n }} {{ s|safe }}", { s = "it's", n = 3 }, { env = env })
  eq(out, "'it''s' 3 it's")
end

T["runtime errors in deep expressions report the statement line"] = function()
  local e = err_of("{% for u in users %}\n{% if u.age > 'x' %}{% endif %}\n{% endfor %}", {
    users = { require("dbdash.util.map").from_pairs({ { "age", 1 } }) },
  })
  eq({ e.kind, e.line }, { "type", 2 })
end

T["file imports: relative to the base dir, cached by mtime, cycles detected"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/lib", "p")
  local function write(name, text)
    local f = assert(io.open(dir .. "/" .. name, "wb"))
    f:write(text)
    f:close()
  end
  write("lib/q.sql", "{% macro q(v) %}'{{ v }}'{% endmacro %}")
  local env = template.env(require("dbdash.db.dialect").get("postgres"), false, dir)
  local src = "{% from 'lib/q.sql' import q %}{{ q('a') }}"
  eq(template.render(src, {}, { env = env }), "'a'")
  -- A changed file is reloaded (new mtime).
  vim.wait(20)
  write("lib/q.sql", "{% macro q(v) %}\"{{ v }}\"{% endmacro %}")
  vim.uv.fs_utime(dir .. "/lib/q.sql", os.time() + 5, os.time() + 5)
  env = template.env(require("dbdash.db.dialect").get("postgres"), false, dir)
  eq(template.render(src, {}, { env = env }), '"a"')
  write("a.sql", "{% import 'b.sql' as b %}")
  write("b.sql", "{% import 'a.sql' as a %}")
  local e = err_of("{% import 'a.sql' as a %}", {}, { env = template.env(require("dbdash.db.dialect").get("postgres"), false, dir) })
  eq(e.message:find("circular import of 'a.sql'") ~= nil, true)
  e = err_of("{% import 'missing.sql' as m %}", {}, { env = template.env(require("dbdash.db.dialect").get("postgres"), false, dir) })
  eq(e.message:find("template not found") ~= nil, true)
end

T["errors inside imported templates name the file"] = function()
  local env = { load_template = require("dbdash.template.loader").dict({ ["h.sql"] = "\n{{ 1 + 'a' }}" }) }
  local e = err_of("{% import 'h.sql' as h %}", {}, { env = env })
  eq({ e.kind, e.line, e.source }, { "type", 2, "h.sql" })
end

T["macros render safe output under autoescape"] = function()
  local env = template.env(require("dbdash.db.dialect").get("postgres"), true)
  eq(template.render([[{% macro m(v) %}x = {{ v }}{% endmacro %}{{ m("it's") }}]], {}, { env = env }), "x = 'it''s'")
end

return T
