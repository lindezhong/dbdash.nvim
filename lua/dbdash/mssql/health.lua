-- :checkhealth dbdash.mssql
return { check = require("dbdash.health_util").network("mssql") }
