-- :checkhealth dbdash.postgres
return { check = require("dbdash.health_util").network("postgres") }
