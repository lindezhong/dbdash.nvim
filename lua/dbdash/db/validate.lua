-- [db] (config/types.lua): each panel's database: its own (replacing the top-level one as a
-- whole) or the top-level one; which driver (database.type, else the URL's scheme), the
-- URL's ${NAME}, password_cmd. The database gets its driver's name as its type. What only
-- one driver knows (its URL's form, its options, its query) is its own validator's
-- ([db <name>], db/drivers/<name>/validate.lua).
local nn = require("dbdash.util.null").nn
local map = require("dbdash.util.map")

---A database as written at `path`, checked and with its type.
---@return dbdash.ConfigDatabase
local function database(ctx, raw, path)
  local db = ctx:expect(path, raw, "map")
  local typ = ctx:expect(path .. ".type", db.type, "string", true)
  local out = {
    type = typ,
    url = ctx:expect(path .. ".url", db.url, "string"),
    password_cmd = nn(db.password_cmd),
    options = ctx:expect(path .. ".options", db.options, "map", true) or map.new(),
  }
  local expanded, env_err = require("dbdash.db.credentials").expand_env(out.url)
  if not expanded then
    return ctx:fail(path .. ".url", "%s", env_err)
  end
  local cmd = out.password_cmd
  if cmd ~= nil then
    local ok = type(cmd) == "string" and cmd ~= ""
    if type(cmd) == "table" then
      ok = #cmd > 0
      for _, a in ipairs(cmd) do
        ok = ok and type(a) == "string"
      end
    end
    if not ok then
      ctx:fail(
        path .. ".password_cmd",
        "password_cmd must be a command string or a list of strings"
      )
    end
  end
  local scheme = expanded:match("^([%a][%w+.-]*)://")
  local name = typ and typ:lower() or scheme
  if name == "oracle" or (scheme and scheme:lower() == "oracle") then
    ctx:fail(path .. ".url", "Oracle is not supported by dbdash.nvim")
  elseif not name then
    ctx:fail(path .. ".url", "cannot infer database type from url %q; set database.type", out.url)
  end
  local ok, d = pcall(require("dbdash.db").driver, name)
  if not ok then
    ctx:fail(path .. (typ and ".type" or ".url"), "unsupported database type '%s'", name)
  end
  out.type = d.name
  return out
end

local M = {
  name = "db",
  checks = "each panel's database: its driver (type or the URL's scheme), ${NAME}, password_cmd",
  validate = function(cfg, ctx)
    local top = nn(cfg.raw.database)
    cfg.database = top ~= nil and database(ctx, top, "database") or nil
    for _, p in ipairs(cfg.panels) do
      local own = p.raw.database
      p.database = own ~= nil and database(ctx, own, p.prefix .. "database") or cfg.database
      if not p.database then
        ctx:fail(
          p.prefix .. "database",
          cfg.listed
              and "missing required field '%sdatabase' (set it in the panel or at the top level)"
            or "missing required field '%sdatabase'",
          p.prefix
        )
      end
    end
  end,
}

return M
