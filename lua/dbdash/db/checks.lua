-- What drivers' validators share (db/drivers/<name>/validate.lua): the databases of a
-- config that use a driver, the URL's form, the driver's options.
local M = {}

---The message of an error raised by the data layer.
local function message(err)
  return type(err) == "table" and err.message or tostring(err)
end

---The databases of `cfg` that use driver `name`, each once, with where it is written:
---{ db, path }.
---@param cfg dbdash.Config
---@return { db: dbdash.ConfigDatabase, path: string }[]
function M.databases(cfg, name)
  local out, seen = {}, {}
  local function add(db, path)
    if db and db.type == name and not seen[db] then
      seen[db] = true
      out[#out + 1] = { db = db, path = path }
    end
  end
  add(cfg.database, "database")
  for _, p in ipairs(cfg.panels) do
    add(p.database, p.prefix .. "database")
  end
  return out
end

---The URL parses (scheme://[user[:password]@]host[:port][/path][?params], ${NAME}
---expanded).
function M.url(db, ctx, path)
  local expanded = require("dbdash.db.credentials").expand_env(db.url) or db.url
  local ok, err = pcall(require("dbdash.db.url").parse, expanded)
  if not ok then
    ctx:fail(path .. ".url", "%s", message(err))
  end
end

---database.options: only those the driver reads (its `options`), each valid.
function M.options(db, driver, ctx, path)
  if driver.options then
    local ok, err =
      pcall(require("dbdash.db.options").check, driver.name, db.options or {}, driver.options, {})
    if not ok then
      ctx:fail(path .. ".options", "%s", message(err))
    end
  end
end

---The validator of driver `name` that checks only what every driver has to: its URL's form
---and its options (a driver with more to check writes its own validate function and calls
---these).
---@return dbdash.config.Validator
function M.validator(name)
  return {
    name = "db " .. name,
    checks = "the " .. name .. " databases: the URL's form, database.options",
    after = { "db" },
    validate = function(cfg, ctx)
      local list = M.databases(cfg, name)
      if #list == 0 then
        return
      end
      local driver = require("dbdash.db").driver(name)
      for _, it in ipairs(list) do
        M.url(it.db, ctx, it.path)
        M.options(it.db, driver, ctx, it.path)
      end
    end,
  }
end

return M
