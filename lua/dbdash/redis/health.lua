-- :checkhealth dbdash.redis

local M = {}

M.check = require("dbdash.health_util").network("redis")

return M
