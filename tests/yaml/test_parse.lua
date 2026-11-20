local yaml = require("dbdash.yaml")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

-- Canonical text form so YAML results can be compared with PyYAML's JSON output.
local function canon(v)
  if v == nil or v == vim.NIL then
    return "null"
  elseif type(v) == "number" then
    return v == math.floor(v) and ("%d"):format(v) or ("%.15g"):format(v)
  elseif type(v) == "string" then
    return ("%q"):format(v)
  elseif type(v) == "boolean" then
    return tostring(v)
  end
  local is_map = map.is_map(v) or getmetatable(v) == getmetatable(vim.empty_dict())
  if not is_map then
    for k in pairs(v) do
      if type(k) ~= "number" then
        is_map = true
        break
      end
    end
  end
  local parts = {}
  if is_map then
    local keys = vim.tbl_keys(v)
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = ("%q"):format(k) .. ":" .. canon(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  for i = 1, #v do
    parts[i] = canon(v[i])
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local dir = "tests/yaml/cases/"
for _, f in ipairs(vim.fn.globpath(dir, "*.yaml", false, true)) do
  local name = vim.fn.fnamemodify(f, ":t")
  T["matches PyYAML: " .. name] = function()
    local got, err = yaml.parse_file(f)
    if got == nil and err and err.message then
      error(tostring(err))
    end
    local json = table.concat(vim.fn.readfile(f:gsub("%.yaml$", ".json")), "\n")
    local want = vim.json.decode(json)
    eq(canon(got), canon(want))
  end
end

T["mappings keep key order and are tagged"] = function()
  local v = yaml.parse("b: 1\na: 2\nc: {}\nd: []\n")
  eq(map.keys(v), { "b", "a", "c", "d" })
  eq(map.is_map(v.c), true)
  eq(map.is_list(v.d), true)
  eq(vim.json.encode({ v.c, v.d }), "[{},[]]")
end

T["records value positions"] = function()
  local _, pos = yaml.parse("query:\n  sql: |\n    SELECT 1\n  args:\n    - name: x\n")
  eq(pos["query.sql"], { line = 3, col = 5 })
  eq(pos["query.args[1].name"].line, 5)
end

local function err_of(text)
  local v, err = yaml.parse(text)
  eq(v, nil)
  return err
end

T["errors report line and column"] = function()
  local e = err_of("a: 1\n  b: 2\n")
  eq({ e.line, e.col, e.message }, { 2, 3, "unexpected indentation" })
  e = err_of("a:\n\tb: 1\n")
  eq(e.line, 2)
  eq(e.message:find("tab") ~= nil, true)
  eq(tostring(err_of('a: "open\n')):match("^line 1, col 4: unterminated") ~= nil, true)
end

T["unsupported features are rejected"] = function()
  local cases = {
    ["a: &x 1\n"] = "anchors",
    ["a: *x\n"] = "anchors",
    ["a: !!str 1\n"] = "tags",
    ["a: 1\n---\nb: 2\n"] = "multiple documents",
    ["? a\n: b\n"] = "complex keys",
    ["a: [1, 2\n"] = "unterminated flow",
  }
  for text, want in pairs(cases) do
    local e = err_of(text)
    eq({ text, e.message:find(want, 1, true) ~= nil }, { text, true })
  end
end

T["leading document marker is allowed"] = function()
  eq(yaml.parse("---\na: 1\n").a, 1)
end

return T
