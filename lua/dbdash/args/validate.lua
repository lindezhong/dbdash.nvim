-- [args] (config/types.lua): the arguments of a config: the shared ones (top-level args)
-- and each panel's own (query.args): their specs (names are identifiers, types known, each
-- name once in a list), what `args` holds in each panel (visible_args) and the key of every
-- value (cfg.args).
local args = require("dbdash.args")
local nn = require("dbdash.util.null").nn

---An argument spec as written at `path`.
---@return dbdash.ArgSpec
local function spec(ctx, a, path)
  a = ctx:expect(path, a, "map")
  if nn(a.key) ~= nil and nn(a.name) == nil then
    ctx:fail(path .. ".key", "'key:' is no longer supported in args; rename it to 'name:'")
  end
  local show, required = nn(a.show), nn(a.required)
  local out = {
    name = ctx:expect(path .. ".name", a.name, "string"),
    type = ctx:expect(path .. ".type", a.type, "string", true) or "string",
    default = nn(a.default),
    required = required == true,
    show = show == nil or show == true,
    description = ctx:expect(path .. ".description", a.description, "string", true),
    choices = ctx:expect(path .. ".choices", a.choices, "list", true),
  }
  if not out.name:match("^[%a_][%w_]*$") then
    ctx:fail(path .. ".name", "argument name '%s' must be an identifier", out.name)
  end
  if not args.TYPES[out.type] then
    ctx:fail(path .. ".type", "unknown argument type '%s'", out.type)
  end
  return out
end

---The specs of the list at `base` ("args", "panels[2].query.args"), each name once.
---@return dbdash.ArgSpec[]
local function list(ctx, raw, base)
  local out, seen = {}, {}
  for i, a in ipairs(ctx:expect(base, raw, "list", true) or {}) do
    local s = spec(ctx, a, ("%s[%d]"):format(base, i))
    if seen[s.name] then
      ctx:fail(("%s[%d].name"):format(base, i), "duplicate argument '%s'", s.name)
    end
    seen[s.name] = true
    out[i] = s
  end
  return out
end

---Every argument (shared, then each panel's) with the key of its value: the name, or
---<panel id>.<name> for a local argument whose name another argument has too.
local function keys(cfg)
  cfg.args = vim.list_extend({}, cfg.shared_args)
  for _, p in ipairs(cfg.panels) do
    vim.list_extend(cfg.args, p.args)
  end
  local count = {}
  for _, s in ipairs(cfg.args) do
    count[s.name] = (count[s.name] or 0) + 1
  end
  for _, s in ipairs(cfg.args) do
    s.key = (s.panel and count[s.name] > 1) and (s.panel_id .. "." .. s.name) or s.name
  end
end

local M = {
  name = "args",
  checks = "arguments: top-level args and each panel's query.args (names, types, each once)",
  validate = function(cfg, ctx)
    cfg.shared_args = list(ctx, cfg.raw.args, "args")
    for _, p in ipairs(cfg.panels) do
      local q = p.raw.query
      local raw = (type(q) == "table" and q ~= vim.NIL) and q.args or nil
      p.args = list(ctx, raw, p.prefix .. "query.args")
      for _, s in ipairs(p.args) do
        s.panel, s.panel_id = p.index, p.id
      end
      -- what `args` holds here: shared arguments, shadowed by local ones of the same name
      local by_name, visible = {}, {}
      for _, s in ipairs(cfg.shared_args) do
        by_name[s.name] = s
        visible[#visible + 1] = s.name
      end
      for _, s in ipairs(p.args) do
        if not by_name[s.name] then
          visible[#visible + 1] = s.name
        end
        by_name[s.name] = s
      end
      p.visible_args = {}
      for i, name in ipairs(visible) do
        p.visible_args[i] = by_name[name]
      end
    end
    keys(cfg)
  end,
}

return M
