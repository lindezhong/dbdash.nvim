-- :checkhealth dbdash.mysql

local M = {}

M.check = require("dbdash.health_util").network("mysql")

return M
