---@meta
-- What Lua in a dashboard sees besides Neovim's globals (lua:// queries, query.transform,
-- {% lua %} blocks and imported .lua modules; :help dbdash-lua). For lua-language-server:
-- add this file's directory to workspace.library to get completion and checks in your own
-- configs' Lua.

---The dashboard's arguments by name; Lua code may assign them (args.x = v).
---@type table<string, any>
args = {}

---The dashboard's metadata, read-only (:help dbdash-meta).
---@type table<string, any>
meta = {}

---The panel's table, kept for as long as the dashboard runs.
---@type table<string, any>
store = {}

---The helpers of Lua code.
---@class dbdash.LuaHelpers
---@field null userdata NULL in results (vim.NIL)
---@field query fun(url: string, query: string, opts: table?): any, table? run a query on any
---  database: its rows (opts.raw: the raw value and, for http, the response)
---@field system fun(cmd: string|string[], opts: table?): { code: integer, stdout: string, stderr: string } run a
---  command without blocking the editor
---@field sleep fun(ms: integer) wait without blocking the editor
---@field checkpoint fun() let the editor run (long loops)
---@field safe fun(s: any): table templates: output s as is, even with autoescape
---@field run fun(args: table?): table run the panel's pipeline again with other arguments
---@field emit fun(value: any)? luastream://: one item
---@field cwd string? luastream://: the working directory
dbdash = {}
