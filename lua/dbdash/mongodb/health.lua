-- :checkhealth dbdash.mongodb (DNS is only needed for mongodb+srv://)
local util = require("dbdash.health_util")

local M = {}

M.check = util.network("mongodb", util.dns)

return M
