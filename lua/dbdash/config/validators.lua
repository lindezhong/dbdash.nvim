-- The validators of configs (ARCHITECTURE.md#startup-and-configuration): found, not listed.
-- Every lua/dbdash/**/validate.lua on the runtimepath is one (config/types.lua): a module's
-- own, built-in or the user's. They run in the order their `after` asks, each given the
-- whole config; config.lua knows none of them.
local M = {}

local found -- the validators in the order they run, once found

---The module of a validate.lua file: lua/dbdash/db/drivers/pg/validate.lua ->
---dbdash.db.drivers.pg.validate.
local function module_of(file)
  local rel = vim.fs.normalize(file):match("/lua/(dbdash/.+)%.lua$")
  return rel and rel:gsub("/", ".")
end

---Order `list` by `after` (each after the validators it names): a name that is unknown or
---a cycle is a bug of the validators, not of a config.
---@param list dbdash.config.Validator[]
---@return dbdash.config.Validator[]
local function order(list)
  local by_name = {}
  for _, v in ipairs(list) do
    if by_name[v.name] then
      error(
        ("two validators named '%s' (%s, %s)"):format(v.name, by_name[v.name].module, v.module),
        0
      )
    end
    by_name[v.name] = v
  end
  table.sort(list, function(a, b)
    return a.name < b.name -- a stable order among validators that do not depend on others
  end)
  local out, state = {}, {}
  local function visit(v, path)
    if state[v] == "done" then
      return
    end
    if state[v] == "visiting" then
      error("validators depend on each other: " .. table.concat(path, " -> "), 0)
    end
    state[v] = "visiting"
    for _, dep in ipairs(v.after or {}) do
      local d = by_name[dep]
      if not d then
        error(
          ("validator '%s' (%s) runs after '%s', which no validator is"):format(
            v.name,
            v.module,
            dep
          ),
          0
        )
      end
      visit(d, vim.list_extend(vim.list_slice(path), { dep }))
    end
    state[v] = "done"
    out[#out + 1] = v
  end
  for _, v in ipairs(list) do
    visit(v, { v.name })
  end
  return out
end

---The validators, in the order they run (found once).
---@return dbdash.config.Validator[]
function M.list()
  if not found then
    local list, seen = {}, {}
    for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/dbdash/**/validate.lua", true)) do
      local mod = module_of(f)
      if mod and not seen[mod] then
        seen[mod] = true
        local v = require(mod)
        if type(v) ~= "table" or type(v.name) ~= "string" or type(v.validate) ~= "function" then
          error(("%s is not a validator (name, checks, after, validate)"):format(mod), 0)
        end
        v.module = mod
        list[#list + 1] = v
      end
    end
    found = order(list)
  end
  return found
end

---Find the validators again (the runtimepath changed: a plugin added, a test's directory).
function M.forget()
  found = nil
end

---Run every validator on the whole config `cfg` (each checks, and completes, its part).
---@param cfg dbdash.Config
---@param ctx dbdash.config.Ctx
function M.run(cfg, ctx)
  for _, v in ipairs(M.list()) do
    ctx.validator = v.name
    v.validate(cfg, ctx)
  end
  ctx.validator = nil
end

return M
