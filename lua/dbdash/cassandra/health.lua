-- :checkhealth dbdash.cassandra

local M = {}

M.check = require("dbdash.health_util").network("cassandra")

return M
