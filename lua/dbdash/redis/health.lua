-- :checkhealth dbdash.redis
return { check = require("dbdash.health_util").network("redis") }
