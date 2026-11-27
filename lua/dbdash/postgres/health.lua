-- :checkhealth dbdash.postgres

local M = {}

M.check = require("dbdash.health_util").network("postgres")

return M
