-- The interface of a config part's rules (lua-language-server annotations; nothing runs
-- here): modules listed in config/validators.lua export M.validators.

---@class dbdash.config.Validator
---@field field "database"|"arg"|"args"|"show"|"panel"|"style"|"dashboard" the part it checks
---@field validate fun(value: any, ctx: dbdash.config.Ctx, path: string): any
---  ctx:fail(path, msg, ...) reports a problem with the line of `path`; a value returned
---  replaces the part (normalized) for the next rules and the config

---@class dbdash.config.Ctx
---@field fail fun(self, path: string, msg: string, ...)
---@field document fun(self, cfg: dbdash.Config): table the config's document (a stand-in
---  dashboard, dashboard/document.lua)

return {}
