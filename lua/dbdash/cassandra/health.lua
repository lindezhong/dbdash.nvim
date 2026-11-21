-- :checkhealth dbdash.cassandra
return { check = require("dbdash.health_util").network("cassandra") }
