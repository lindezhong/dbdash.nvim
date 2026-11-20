-- Compare the Lua engine against outputs recorded from real Jinja2 (tests/template/gen.py).
local template = require("dbdash.template")
local yaml = require("dbdash.yaml")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local cases = vim.json.decode(table.concat(vim.fn.readfile("tests/template/cases.json"), "\n"))

for _, c in ipairs(cases) do
  T[c.name] = function()
    -- The YAML parser keeps mapping order, which Jinja output depends on.
    local ctx = assert(yaml.parse(c.ctx))
    local opts = nil
    if c.files then
      opts = { env = { load_template = require("dbdash.template.loader").dict(c.files) } }
    end
    local out, err = template.render(c.template, ctx, opts)
    if c.error then
      eq({ err and err.kind, err and err.line, out }, { c.error.type, c.error.line, nil })
    else
      if err then
        error(tostring(err))
      end
      eq(out, c.lua_expected or c.expected)
    end
  end
end

return T
