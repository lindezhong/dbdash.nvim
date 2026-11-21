-- :checkhealth dbdash.mongodb (DNS is only needed for mongodb+srv://)
local util = require("dbdash.health_util")
return { check = util.network("mongodb", util.dns) }
