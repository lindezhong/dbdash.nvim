-- :checkhealth dbdash.mssql

local M = {}

M.check = require("dbdash.health_util").network("mssql")

return M
