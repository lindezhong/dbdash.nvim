-- The interfaces of the data layer (lua-language-server annotations; nothing runs here):
-- drivers, their connections and the context of a run (ARCHITECTURE.md#interfaces).

---@class dbdash.db.ConnInfo: dbdash.db.Url
---@field options table driver-specific options from the config (database.options)
---@field base_dir string? directory of the config file (for relative sqlite paths)

---@class dbdash.db.ExecuteOpts
---@field max_rows integer
---@field timeout integer

---@class dbdash.db.Connection
---@field execute fun(self, query: string, opts: dbdash.db.ExecuteOpts): dbdash.db.ResultSet
---@field close fun(self)
---@field server_version fun(self): string?

---@class dbdash.db.Driver a data source (ARCHITECTURE.md#data-sources): it has connect (a
---  database, queried on every tick by db/driver.lua's producer) or produce (a source that
---  sends data)
---@field name string
---@field schemes string[] URL schemes (default { name })
---@field dialect (string|dbdash.template.Dialect)? how template values are written in its queries:
---  a name of template/dialect.lua (default: the driver's name) or a dialect
---@field capabilities { tls: boolean, sql: boolean, query_language: string }?
---@field query_optional boolean? a config may leave query.sql out
---@field options table<string, string|fun(v: any): string?>? the database.options it reads
---  (db/options.lua checks them; nil: not checked)
---@field parse_url (fun(u: dbdash.db.ConnInfo): dbdash.db.ConnInfo)?
---@field connect (fun(info: dbdash.db.ConnInfo): dbdash.db.Connection)? a database
---@field cancel (fun(conn: dbdash.db.Connection, info: dbdash.db.ConnInfo))? stop the query
---  running on `conn` on the server (inside a task, while the query's own task waits)
---@field produce (fun(info: dbdash.db.ConnInfo, query: string, ctx: dbdash.db.StreamCtx))? a
---  source that sends data until it returns (:help dbdash-push)

---@class dbdash.db.QueryOpts
---@field max_rows integer? (default: dbdash.db.defaults)
---@field timeout integer? ms, overrides the url's timeout
---@field options table? driver options (database.options)
---@field base_dir string?
---@field password_cmd string|string[]? command printing the password (database.password_cmd)
---@field args table? dashboard arguments (lua:// scripts get them as `args`)
---@field meta table? dashboard metadata (lua:// scripts get it as `meta`)
---@field lua { store: table, helpers: table }? lua:// scripts: the panel's store and dbdash helpers
---@field source string? config file name for messages (lua:// error locations)
---@field line integer? line of the query in the config file (lua:// error locations)
---@field raw boolean? return a raw driver result (lua://, http) as is, for query.transform;
---   otherwise it is checked and turned into a result set
---@field allow_writes boolean? the query may write files (http(s):// curl -c cookie files);
---   set for configs that were trusted with it
---@field cancel dbdash.db.CancelToken? cancelling it stops the query (see M.query)
---@field on_status fun(text: string)? push sources: their status changed (M.run)
---@field wait_tick (fun(): boolean)? a run of a driver with connect: waits for its next tick, false
---  when the run stops (default: one tick)

---@class dbdash.db.StreamCtx what a push source's producer gets
---@field writer fun(delimiter: string?, vars: table?): fun(text: string) a stream: the text
---   written is cut at `delimiter` (default "\n"), each piece is one item
---@field emit fun(value: any, vars: table?, tag: any?) one result
---@field fail fun(err: any, tag: any?) a query's error (the run goes on)
---@field wait_tick fun(not_before: integer?, failures: integer?): boolean the next tick of a
---  database's run (false: it stops); backing off, not before `not_before` (loop time, ms)
---@field report fun(ok: boolean)? set by a producer: how the consumer took a result
---@field ticked boolean the run has ticks of its own (opts.wait_tick): the consumer reports
---  each result (handle:report)
---@field opts dbdash.db.QueryOpts the run's options
---@field prep_error table? the URL or driver could not be prepared
---@field cancel dbdash.db.CancelToken cancelled when the stream stops
---@field stats { items: integer, truncated: integer, rejected: table<integer, integer> }
---@field set_status fun(text: string) what the source is doing ("listening 127.0.0.1:8765"),
---   shown in the panel (handle.status, opts.on_status)
---@field on_stop fun(fn: fun()) cleanup when the stream ends or stops (kill a process, ...)
---@field base_dir string? the config file's directory
---@field options table database.options
---@field args table?, meta table?, lua table?, source string?, line integer? as for lua://
---@field timeout integer ms (query.timeout, else the URL's)

local M = {}

return M
