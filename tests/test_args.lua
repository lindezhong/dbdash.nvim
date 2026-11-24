local args = require("dbdash.args")
local map = require("dbdash.util.map")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local specs = {
  { name = "min_age", type = "number", default = 18 },
  { name = "limit", type = "int", default = 10 },
  { name = "active", type = "boolean", default = true },
  { name = "departments", type = "list", default = { "IT", "HR" } },
  { name = "ids", type = "list", default = { 1, 2, 3 } },
  { name = "filters", type = "map" },
  { name = "label", type = "string", required = true },
}

local function err(fn, ...)
  local ok, e = pcall(fn, ...)
  eq(ok, false)
  return e.message
end

T["split handles escapes and quotes"] = function()
  eq(args.split("a,b\\,c,'d,e',\"f\"", ","), { "a", "b,c", "d,e", "f" })
  eq(args.split("k:v:w", ":", 2), { "k", "v:w" })
  eq(err(args.split, "'open", ","):find("unterminated") ~= nil, true)
end

T["cli values are parsed by declared type"] = function()
  local v = args.parse_cli(specs, {
    "min_age=30.5",
    "limit=5",
    "active=no",
    "departments=IT,HR\\,Ops",
    "ids=4,5",
    "filters=region:Asia,level:'senior:1'",
    "label=a=b",
  })
  eq(v.min_age, 30.5)
  eq(v.limit, 5)
  eq(v.active, false)
  eq(v.departments, { "IT", "HR,Ops" })
  eq(v.ids, { 4, 5 })
  eq(map.keys(v.filters), { "region", "level" })
  eq(v.filters.level, "senior:1")
  eq(v.label, "a=b")
end

T["cli errors"] = function()
  eq(err(args.parse_cli, specs, { "limit=1.5" }), "argument 'limit': \"1.5\" is not an integer")
  eq(err(args.parse_cli, specs, { "min_age=old" }):find("not a number") ~= nil, true)
  eq(err(args.parse_cli, specs, { "active=maybe" }):find("not a boolean") ~= nil, true)
  eq(err(args.parse_cli, specs, { "nope=1" }):find("unknown argument 'nope' %(known: min_age") ~= nil, true)
  eq(err(args.parse_cli, specs, { "limit" }):find("expected name=value") ~= nil, true)
  eq(err(args.parse_cli, specs, { "limit=1", "limit=2" }):find("given twice") ~= nil, true)
  eq(err(args.parse_cli, specs, { "ids=1,x" }):find("not a number") ~= nil, true)
  eq(err(args.parse_cli, specs, { "filters=novalue" }):find("key:value") ~= nil, true)
end

T["format_value round-trips"] = function()
  for _, case in ipairs({
    { specs[4], { "a,b", "c:d", "e" } },
    { specs[6], map.from_pairs({ { "k", "v,1" }, { "x:y", "z" } }) },
    { specs[3], false },
    { specs[1], 2.5 },
  }) do
    local text = args.format_value(case[2])
    eq(args.parse_value(case[1], text), case[2])
  end
  eq(args.format_value(nil), "")
end

T["precedence: cli > modified > interactive > default"] = function()
  local st = args.new_state({ limit = 1 })
  st.interactive.limit = 3
  st.interactive.min_age = 21
  eq(args.resolve(specs, st).limit, 1)
  args.set_modified(st, "limit", 2)
  eq(args.resolve(specs, st).limit, 2)
  local vars = args.resolve(specs, st)
  eq({ vars.min_age, vars.active, vars.filters, vars.label }, { 21, true, vim.NIL, vim.NIL })
  eq(#args.missing_required(specs, st), 1)
  st.interactive.label = "x"
  eq(#args.missing_required(specs, st), 0)
  args.reset(st)
  eq(args.resolve(specs, st).limit, 10)
end

-- Shared arguments (key = name) and local ones of panels (key = <panel id>.<name>).
local scoped = {
  { name = "region", key = "region", type = "string", default = "EU" },
  { name = "region", key = "orders.region", panel = 1, type = "string", default = "US" },
  { name = "limit", key = "orders.limit", panel = 1, type = "int", default = 5 },
  { name = "limit", key = "2.limit", panel = 2, type = "int", default = 9 },
}

T["cli: a bare name sets every argument of that name, <panel>.name one panel's"] = function()
  eq(args.parse_cli(scoped, { "region=JP" }), { region = "JP", ["orders.region"] = "JP" })
  eq(args.parse_cli(scoped, { "limit=3" }), { ["orders.limit"] = 3, ["2.limit"] = 3 })
  eq(args.parse_cli(scoped, { "orders.region=CN" }), { ["orders.region"] = "CN" })
  eq(err(args.parse_cli, scoped, { "2.region=CN" }), "panel '2' has no local argument 'region' (use region= for the shared one)")
  eq(err(args.parse_cli, scoped, { "limit=x" }):find("not a number") ~= nil, true)
  -- <panel>.name wins over the bare name, in either order.
  eq(args.parse_cli(scoped, { "orders.region=CN", "region=JP" }), { region = "JP", ["orders.region"] = "CN" })
  eq(err(args.parse_cli, scoped, { "region=JP", "region=CN" }), "argument 'region' given twice")
  eq(args.keys(scoped), { "region", "orders.region", "limit", "orders.limit", "2.limit" })
end

T["resolve_panel: shared values, shadowed by the panel's local ones"] = function()
  local st = args.new_state(args.parse_cli(scoped, { "region=JP", "orders.region=CN" }))
  local orders = { visible_args = { scoped[2], scoped[3] } }
  local other = { visible_args = { scoped[1], scoped[4] } }
  eq(args.resolve_panel(orders, st), { region = "CN", limit = 5 })
  eq(args.resolve_panel(other, st), { region = "JP", limit = 9 })
end

return T
