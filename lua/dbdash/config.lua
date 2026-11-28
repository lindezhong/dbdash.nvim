-- Load a dashboard config file (ARCHITECTURE.md#startup-and-configuration): the YAML, then
-- the structure (the panels: a config without `panels:` is its only one; the top-level
-- defaults merged into each), then the validators (config/validators.lua), each given the
-- whole config. This file knows no field's meaning and no validator.
local yaml = require("dbdash.yaml")
local map = require("dbdash.util.map")

local M = {}

local nn = require("dbdash.util.null").nn

---@class dbdash.ConfigDatabase
---@field type string
---@field url string
---@field options table
---@field password_cmd (string|string[])?

---@class dbdash.ConfigQuery
---@field sql string
---@field sql_line integer
---@field transform string?
---@field transform_line integer
---@field autoescape boolean
---@field max_rows integer
---@field timeout integer?
---@field args dbdash.ArgSpec[]

---@class dbdash.Config
---@field path string absolute path of the YAML file
---@field dir string directory containing the file
---@field positions table<string, {line: integer, col: integer}>
---@field listed boolean the config lists its panels (`panels:`): where its fields are
---@field raw table the config as written (its top level)
---@field panels dbdash.PanelConfig[] the panels (one when the config has no `panels:`)
---The validators' (each fills in its own part):
---@field database dbdash.ConfigDatabase? top-level database: the default of every panel
---@field refresh_all integer? ms: the top-level interval, a refresh of every panel
---@field title string? the dashboard's title (top-level `title`)
---@field description string? the dashboard's description (a template, shown as Markdown)
---@field description_line integer
---@field shared_args dbdash.ArgSpec[] top-level args
---@field args dbdash.ArgSpec[] shared and local arguments, each with its `key`
---@field style_rules dbdash.css.Rule[]? the dashboard's style sheet

---@class dbdash.PanelConfig
---@field index integer
---@field id string `id:` or the index; local arguments are given as <id>.<name>
---@field prefix string where its fields are written: "" or "panels[i]."
---@field raw { database: table?, query: table?, show: table?, style: table? } as written,
---  the top-level defaults merged in (query, show; the database only when it has none)
---The validators' (each fills in its own part):
---@field database dbdash.ConfigDatabase
---@field query dbdash.ConfigQuery
---@field show table
---@field args dbdash.ArgSpec[] local arguments (query.args), only for this panel
---@field visible_args dbdash.ArgSpec[] what `args` holds in this panel: the shared arguments,
---  each shadowed by a local one of the same name
---@field shown_args dbdash.ArgSpec[] the arguments on this panel's args_show line
---@field follows_global boolean no timer of its own: the global refresh (cfg.refresh_all)
---  comes as often or more often than show.interval
---@field style_rules dbdash.css.Rule[]? the panel's style sheet (inline, scoped)

---Parse a duration such as 30, "30s", "5m", "1h", "500ms" into milliseconds.
M.parse_duration = require("dbdash.util.duration").parse

---What a validator is given with the config (config/types.lua): the file, the line of
---every path, and helpers that report a problem with its line.
---@class dbdash.config.Ctx
---@field file string
---@field pos table<string, { line: integer, col: integer }>
---@field validator string? the validator running (its name goes into the errors)
local Ctx = {}
Ctx.__index = Ctx
M.Ctx = Ctx

---The document of the config as a dashboard would have it (dashboard/document.lua), for
---rules that need computed styles (the grid).
function Ctx:document(cfg)
  return require("dbdash.dashboard.document").from_config(cfg)
end

---Raise a config error at the line of `path` (or of its nearest parent with one), saying
---which validator found it. It never returns (`return ctx:fail(...)` and
---`x or ctx:fail(...)` keep their code's types).
---@return any
function Ctx:fail(path, msg, ...)
  -- Keys inside a flow mapping ({ a: 1 }) have no position: use the nearest parent's.
  local p, at = self.pos[path], path
  while not p do
    local parent = at:gsub("%[%d+%]$", "", 1)
    if parent == at then
      parent = at:gsub("%.[^.%[]*$", "", 1)
    end
    if parent == at then
      break
    end
    at = parent
    p = self.pos[at]
  end
  local where = p and (":%d:%d"):format(p.line, p.col) or ""
  local who = self.validator and ("[" .. self.validator .. "] ") or ""
  require("dbdash.util.error").raise(
    "config",
    ("%s%s: %s%s"):format(self.file, where, who, msg:format(...))
  )
end

---The value at `path` when it is a `kind` ("map", "list", "integer" or a Lua type); nil
---when it is missing and optional, else an error.
---@param kind string
---@param optional boolean?
---@return any
function Ctx:expect(path, v, kind, optional)
  v = nn(v)
  if v == nil then
    if not optional then
      self:fail(path, "missing required field '%s'", path)
    end
    return nil
  end
  local ok
  if kind == "map" then
    ok = map.is_map(v)
  elseif kind == "list" then
    ok = map.is_list(v)
  elseif kind == "integer" then
    ok = type(v) == "number" and v == math.floor(v)
  else
    ok = type(v) == kind
  end
  if not ok then
    self:fail(path, "'%s' must be a %s", path, kind)
  end
  return v
end

---A duration at `path` in ms (nil when unset), else an error.
function Ctx:duration(path, v)
  local ms, err = M.parse_duration(v)
  if err then
    self:fail(path, "'%s': %s", path, err)
  end
  return ms
end

-- The structure ---------------------------------------------------------------------------

---`b` over `a`: mappings merge key by key (recursively), anything else (lists too) replaces.
function M.merge(a, b)
  if b == nil then
    return a
  end
  if not (map.is_map(a) and map.is_map(b)) then
    return b
  end
  local out = map.new()
  for k, v in map.pairs(a) do
    map.set(out, k, v)
  end
  for k, v in map.pairs(b) do
    map.set(out, k, M.merge(nn(a[k]), v))
  end
  return out
end

---Panel i's id (`id:`, else its index), unique.
local function panel_id(ctx, listed, raw, i, prefix, ids)
  local id = tostring(i)
  if listed and nn(raw.id) ~= nil then
    id = ctx:expect(prefix .. "id", raw.id, "string")
    if not id:match("^[%a_][%w_]*$") then
      ctx:fail(prefix .. "id", "panel id '%s' must be an identifier", id)
    end
  end
  if ids[id] then
    ctx:fail(prefix .. "id", "duplicate panel id '%s' (panels[%d])", id, ids[id])
  end
  ids[id] = i
  return id
end

---The panels of `data`: `panels:` lists them, else the top level is the only one (the
---same dashboard, written shorter: only where things are written differs). Each gets the
---top-level query and show merged under its own; its database is its own (validators give
---it the top-level one when it has none).
local function panels(ctx, cfg, data)
  local listed = cfg.listed
  local list
  if listed then
    list = ctx:expect("panels", data.panels, "list")
    if #list == 0 then
      ctx:fail("panels", "panels must not be empty")
    end
  else
    list = { { query = nn(data.query), show = nn(data.show) } }
  end
  local top_query = listed and nn(data.query) or nil
  local top_show = listed and nn(data.show) or nil
  local ids = {}
  for i, raw in ipairs(list) do
    local prefix = listed and ("panels[%d]."):format(i) or ""
    if listed then
      ctx:expect(("panels[%d]"):format(i), raw, "map")
      -- Inherited fields report the line of the top-level default.
      for path, p in pairs(ctx.pos) do
        if (path:match("^query%.") or path:match("^show%.")) and ctx.pos[prefix .. path] == nil then
          ctx.pos[prefix .. path] = p
        end
      end
    end
    cfg.panels[i] = {
      index = i,
      id = panel_id(ctx, listed, raw, i, prefix, ids),
      prefix = prefix,
      raw = {
        database = nn(raw.database),
        query = M.merge(top_query, nn(raw.query)),
        show = M.merge(top_show, nn(raw.show)),
        style = listed and nn(raw.style) or nil,
      },
    }
  end
end

---Read parsed YAML data: its structure, then every validator (config/validators.lua) on
---the whole config.
---@param data any
---@param file string used in error messages
---@param positions table<string, {line: integer, col: integer}>?
---@return dbdash.Config
function M.validate(data, file, positions)
  local ctx = setmetatable({ file = file, pos = positions or {} }, Ctx)
  if not map.is_map(data) then
    ctx:fail("", "config must be a mapping with database, query and show sections")
  end
  local cfg = {
    path = file,
    dir = vim.fs.dirname(file),
    positions = ctx.pos,
    listed = nn(data.panels) ~= nil,
    raw = data,
    panels = {},
  }
  panels(ctx, cfg, data)
  require("dbdash.config.validators").run(cfg, ctx)
  return cfg
end

---Load a config file.
---@param path string
---@return dbdash.Config? cfg, {phase: string, message: string}? err
function M.load(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local data, pos = yaml.parse_file(path)
  if data == nil and pos then
    local where = pos.line > 0 and (":%d:%d"):format(pos.line, pos.col) or ""
    return nil, { phase = "config", message = ("%s%s: %s"):format(path, where, pos.message) }
  end
  local ok, res = pcall(M.validate, data, path, pos)
  if not ok then
    local e = res ---@type any (the error)
    if type(e) == "table" and e.phase then
      return nil, res
    end
    error(res, 0)
  end
  return res
end

return M
