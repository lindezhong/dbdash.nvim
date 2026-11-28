-- [db numbers]: what every driver checks (the URL's form, database.options against its
-- `options`), and a rule of its own: step is positive.
local checks = require("dbdash.db.checks")

local M = {
  name = "db numbers",
  checks = "the numbers databases: the URL, database.options (step > 0)",
  after = { "db" },
  validate = function(cfg, ctx)
    for _, it in ipairs(checks.databases(cfg, "numbers")) do
      checks.url(it.db, ctx, it.path)
      checks.options(it.db, require("dbdash.db").driver("numbers"), ctx, it.path)
      local step = it.db.options.step
      if step ~= nil and step <= 0 then
        ctx:fail(it.path .. ".options.step", "step must be positive, not %s", step)
      end
    end
  end,
}

return M
