-- :checkhealth dbdash.mysql
return { check = require("dbdash.health_util").network("mysql") }
