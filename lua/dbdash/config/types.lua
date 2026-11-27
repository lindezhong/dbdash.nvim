-- The interface of a config part's rules (lua-language-server annotations; nothing runs
-- here): modules listed in config/validators.lua export M.validators.

---@class dbdash.config.Validator
---@field field "database"|"style"|string the part of a config it checks
---@field validate fun(value: any, ctx: dbdash.config.Ctx, path: string)
---  ctx:fail(path, msg, ...) reports a problem with the line of `path`

---@class dbdash.config.Ctx
---@field fail fun(self, path: string, msg: string, ...)

return {}
