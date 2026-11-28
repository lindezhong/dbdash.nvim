-- A run of a panel's pipeline (a refresh, an item of a source that sends data, or a
-- dbdash.run() callback): its record (meta.run), its arguments, its templates and the
-- globals of its Lua code. Also the template rendering of a dashboard (render_text).
local args = require("dbdash.args")
local db = require("dbdash.db")
local template = require("dbdash.template")
local dialect = require("dbdash.db.dialect")

local M = {}

---@class dbdash.RunLife
---@field n integer dbdash.run() calls so far
---@field runs table[] the run records (meta.runs)
---@field version integer bumped when a record changes
---@field cancel dbdash.db.CancelToken

---@class dbdash.Run one run of a panel's pipeline: a refresh (depth 0) or a callback
---@field panel dbdash.Panel
---@field values table<string, any> the arguments by name
---@field args table what Lua code sees as `args`
---@field depth integer 0 for a refresh, n for a callback n levels deep (meta.run.depth)
---@field counter dbdash.RunLife the refresh's life: dbdash.run() calls so far, the run
---  records (meta.runs) and the token that cancels the refresh, shared by its callbacks
---@field record table this run's record (meta.run): id, kind, depth, parent_id, refresh_id,
---  args, started_at, finished_at, elapsed_ms, ok, error, sql, query, result
---@field lua { store: table, helpers: table } globals of all Lua code of the run
---@field meta table? the metadata of this run
---@field life dbdash.RunLife the same as counter
---@field code string? the rendered query.transform
---@field item { value: any, vars: table }? the item of a source that sends data
---@field maps table[] the template `args` mappings of this run
---@field meta_maps table[] the template `meta` mappings of this run
---@field meta_version integer?
---@field seen table the values when the run started
---@field read_only boolean?
local Run = {}
Run.__index = Run
M.Run = Run

---Render query.sql and query.transform for the current arguments: one template path for
---both (same variables, imports and helpers); the transform is Lua, so never autoescaped.
---Runs inside a util.async task (template Lua may wait on dbdash.* helpers); raises a
---template or database error.
---@return string sql, string? transform_code
function Run:render_templates()
  return self:render_sql(), self:render_transform()
end

---query.sql rendered for the run (autoescaped as query.autoescape says).
---@param cancel dbdash.db.CancelToken? the token that stops it (default: the life's)
function Run:render_sql(cancel)
  local q = self.panel.cfg.query
  return self:render(q.sql, q.sql_line, { autoescape = q.autoescape, cancel = cancel })
end

---query.transform rendered for the run (Lua code: never autoescaped), or nil without one.
function Run:render_transform()
  local q = self.panel.cfg.query
  return q.transform and self:render(q.transform, q.transform_line) or nil
end

---Render a template of the panel (its query, its transform, its description) for the run:
---the one place a panel's template options are made (Run:template_opts).
---@param extra table? options over them (autoescape, cancel)
function Run:render(text, line, extra)
  local o = self:template_opts()
  return M.render_text(self.panel.d, text, line, extra and vim.tbl_extend("force", o, extra) or o)
end

---The options of M.render_text for the run's templates (and its `meta`, set on it; a
---refresh's is the panel's meta too).
function Run:template_opts()
  local p = self.panel
  local q = p.cfg.query
  self.meta = require("dbdash.metadata").values(p, self) -- `meta` of templates and Lua
  if self.depth == 0 and not self.read_only then
    p.meta = self.meta
  end
  return {
    dialect = dialect.get(db.driver(p.cfg.database.type).dialect),
    specs = p.cfg.visible_args,
    values = self.args,
    meta = self.meta,
    lua = self.lua,
    run = self,
    set_arg = function(name, v)
      self:set_arg(name, v)
    end,
    timeout = q.timeout,
    cancel = self.life.cancel,
    on_allow = function()
      p:restart()
    end,
  }
end

---A run of panel `p`'s pipeline with `values` (default: the current arguments).
---@param p dbdash.Panel
---@param parent dbdash.Run? the run this one is a callback of
---@param kind "refresh"|"callback"|"push"|"render"? render: :DbDashShowSQL and descriptions
---  (not a run of the life); push: an item of a push source; default refresh, or callback
---  with a parent
---@return dbdash.Run
function M.new(p, values, parent, kind)
  local run = setmetatable({
    panel = p,
    values = values or args.resolve_panel(p.cfg, p.d.arg_state),
    depth = parent and parent.depth + 1 or 0,
    -- The life: callbacks so far, records, and the cancel token of the refresh.
    counter = parent and parent.counter
      or { n = 0, runs = {}, version = 0, cancel = require("dbdash.db.cancel").new() },
    item = parent and parent.item or nil, -- push sources: the item a callback works on too
  }, Run)
  run.life = run.counter
  -- The run record: meta.run, and in meta.runs (meta.prev_runs ... once the life is over).
  local uuid = require("dbdash.util.uuid")
  local id = uuid.v7()
  run.record = {
    id = id,
    kind = kind or (parent and "callback" or "refresh"),
    depth = run.depth,
    parent_id = parent and parent.record.id or nil,
    refresh_id = parent and parent.record.refresh_id or id,
    args = vim.deepcopy(run.values),
    started_at = uuid.now_ms(),
  }
  if run.record.kind ~= "render" then
    table.insert(run.life.runs, run.record)
    run.life.version = run.life.version + 1
  end
  run.meta_maps = {} -- the template `meta` mappings of this run (their run / runs follow)
  run.maps = {} -- the template `args` mappings of this run (kept in step with assignments)
  run.args = run.values -- Lua code sees (and may assign) the values; see Run:sync_args
  run.seen = vim.deepcopy(run.values)
  run.lua = {
    store = p.store,
    helpers = run:helpers(),
    after = function()
      run:sync_args()
    end,
  }
  return run
end

---Close the run's record: finished_at, elapsed_ms, ok and error.
function Run:finish(err)
  local r = self.record
  r.finished_at = require("dbdash.util.uuid").now_ms()
  r.elapsed_ms = r.finished_at - r.started_at
  r.ok = err == nil
  r.error = err ~= nil and require("dbdash.util.error").format(err) or nil
  self.life.version = self.life.version + 1
end

---After Lua code ran (a {% lua %} block, a module, query.transform, lua://): apply the
---arguments it assigned (`args.x = v`) with Run:set_arg. An invalid one is put back
---and raises.
function Run:sync_args()
  local run = self
  -- Templates see meta.run / meta.runs as they are now (a callback may have run).
  if #run.meta_maps > 0 and run.meta_version ~= run.life.version then
    run.meta_version = run.life.version
    local metadata = require("dbdash.metadata")
    local map = require("dbdash.util.map")
    for _, m in ipairs(run.meta_maps) do
      map.set(m, "run", metadata.template_value(run.record))
      map.set(m, "runs", metadata.template_value(run.life.runs))
    end
  end
  local values, seen = run.values, run.seen
  local names = {}
  for k in pairs(values) do
    names[k] = true
  end
  for k in pairs(seen) do
    names[k] = true
  end
  for name in pairs(names) do
    local v = values[name]
    if not vim.deep_equal(v, seen[name]) then
      values[name] = seen[name] -- set_arg stores it once it is valid
      run:set_arg(name, v)
    end
  end
end

---Assign argument `name` in a run (Lua `args.x = v`, {% set args.x = v %}): checked, then
---seen by the rest of the run (its templates, transform, lua://) and kept like an edit in
---the dashboard (from the next refresh on; a local argument shadows a shared one). A
---callback's run keeps its own values: the caller's do not change. Raises a message.
function Run:set_arg(name, v)
  local run = self
  if run.read_only then
    error("arguments cannot be assigned in a description", 0)
  end
  local spec = type(name) == "string" and run.panel:arg_spec(name)
  if not spec then
    error(("'%s' is not an argument of this panel"):format(tostring(name)), 0)
  end
  if v == vim.NIL then
    v = nil
  end
  local bad = args.check_value(spec, v)
  if bad then
    error(bad, 0)
  end
  run.values[name] = v == nil and vim.NIL or v
  run.seen[name] = vim.deepcopy(run.values[name])
  local R = require("dbdash.template.runtime")
  for _, m in ipairs(run.maps) do
    require("dbdash.util.map").set(m, name, R.from_lua(v))
  end
  args.set_modified(run.panel.d.arg_state, spec.key, v == nil and vim.NIL or v)
end

---The `dbdash` table of a run's Lua code: the shared helpers plus the run's own:
---dbdash.run(args) runs the panel's pipeline again with `args` merged over the run's
---arguments (a callback: meta.run.kind is "callback", meta.run.depth its depth) and returns
---its rows as Lua data.
function Run:helpers()
  local run, p = self, self.panel
  local own = {
    run = function(over)
      if over ~= nil and type(over) ~= "table" then
        error(("dbdash.run: expected a table of arguments, got %s"):format(type(over)), 2)
      end
      local limits = require("dbdash.options").current.lua
      if run.counter.n + 1 > limits.max_callbacks then
        error(
          ("dbdash.run: more than %d callbacks in one refresh (lua.max_callbacks)"):format(
            limits.max_callbacks
          ),
          2
        )
      end
      if run.depth + 1 > limits.max_callback_depth then
        error(
          ("dbdash.run: callbacks nested deeper than %d (lua.max_callback_depth)"):format(
            limits.max_callback_depth
          ),
          2
        )
      end
      local values = {}
      for k, v in pairs(run.values) do
        values[k] = v
      end
      for name, v in pairs(over or {}) do
        local spec = type(name) == "string" and p:arg_spec(name)
        if not spec then
          error(("dbdash.run: '%s' is not an argument of this panel"):format(tostring(name)), 2)
        end
        local bad = args.check_value(spec, v)
        if bad then
          error("dbdash.run: " .. bad, 2)
        end
        values[name] = v
      end
      run.counter.n = run.counter.n + 1
      local child = M.new(p, values, run)
      local ok, err = pcall(p.pipeline, p, child)
      child:finish(not ok and err or nil)
      if not ok then
        error(err, 0)
      end
      return child.record.result
    end,
  }
  return setmetatable(own, { __index = require("dbdash.db.lua_env").helpers })
end

---@class dbdash.dashboard.RenderTextOpts
---@field dialect table?
---@field autoescape boolean?
---@field specs dbdash.ArgSpec[]
---@field values table
---@field meta table
---@field lua table?
---@field timeout integer?
---@field cancel dbdash.db.CancelToken?
---@field on_allow fun()?
---@field run dbdash.Run? the run whose `args` mapping this is
---@field set_arg fun(name: string, v: any)? {% set args.x = v %}

---The options of M.render_text for a template of dashboard `d` outside any panel (its
---description): the shared arguments, the dashboard's metadata; it changes no argument.
function M.dashboard_opts(d)
  local cfg = d.cfg
  local values = args.resolve(cfg.shared_args, d.arg_state)
  local seen = vim.deepcopy(values)
  local function refuse()
    error("arguments cannot be assigned in a description", 0)
  end
  return {
    dialect = cfg.database and dialect.get(db.driver(cfg.database.type).dialect) or nil,
    specs = cfg.shared_args,
    values = values,
    meta = require("dbdash.metadata").dashboard_values(d),
    lua = {
      after = function()
        if not vim.deep_equal(values, seen) then
          refuse()
        end
      end,
    },
    set_arg = refuse,
  }
end

---Render template `text` (at `line` of the config) of dashboard `d`. Templates see exactly
---two names: args.<name> (o.specs with o.values) and meta.<name> (o.meta); imported
---templates and Lua in templates too. Inside a util.async task; raises template errors.
---@param o dbdash.dashboard.RenderTextOpts
---  lua: { store, helpers } globals of Lua in the template ({% lua %}, imported .lua);
---  run: the run whose `args` mapping this is; set_arg: {% set args.x = v %}
function M.render_text(d, text, line, o)
  local metadata = require("dbdash.metadata")
  local map = require("dbdash.util.map")
  local R = require("dbdash.template.runtime")
  local args_map = map.new()
  for _, spec in ipairs(o.specs) do
    local v = o.values[spec.name]
    map.set(args_map, spec.name, type(v) == "table" and R.from_lua(v) or v)
  end
  if o.run then
    table.insert(o.run.maps, args_map)
  end
  -- args and meta are read-only for the template's methods (args change with set_arg).
  local vars =
    { args = R.freeze(args_map, "args"), meta = R.freeze(metadata.for_template(o.meta), "meta") }
  if o.run then
    table.insert(o.run.meta_maps, vars.meta)
  end
  local env = template.env(o.dialect, o.autoescape == true, d.cfg.dir)
  env.context = vars
  -- Lua in templates ({% lua %}, imported .lua): args, meta and the query timeout.
  env.lua = {
    args = o.values,
    meta = metadata.for_lua(o.meta),
    store = o.lua and o.lua.store,
    -- the helpers of Lua code, dbdash.query included (the template engine knows no data)
    helpers = o.lua and o.lua.helpers or require("dbdash.db.lua_env").helpers,
    after = o.lua and o.lua.after,
  }
  env.timeout = o.timeout or require("dbdash.options").default_ms("timeout")
  env.cancel = o.cancel -- cancelling the refresh stops Lua in the template
  env.set_arg = o.set_arg
  env.check_file = function(path, t, kind)
    M.check_file(d, path, t, kind, o.on_allow)
  end
  local out, err = template.render(text, vars, {
    env = env,
    source = vim.fn.fnamemodify(d.path, ":~:."),
    line_offset = line - 1,
  })
  if not out then
    error(err, 0)
  end
  return out
end

---check_file for any template of dashboard `d`; `on_allow` runs when it is allowed then.
function M.check_file(d, path, text, kind, on_allow)
  local trust = require("dbdash.trust")
  if kind == "template" and not trust.has_lua_block(text) then
    return
  end
  if not trust.required(d.path) or trust.covers(d.path, path, text) then
    return
  end
  local files = trust.collect(d.path, d.cfg)
  local real = trust.real(path)
  local listed = false
  for _, f in ipairs(files) do
    listed = listed or f.path == real
  end
  if not listed then
    files[#files + 1] = { path = real, kind = kind, text = text }
  end
  local ok, why = trust.check(d.path, files, function(answer)
    if answer == "allow" and on_allow then
      on_allow()
    end
  end)
  if not ok then
    error(
      require("dbdash.template.errors").new(
        "trust",
        why
          or ("%s runs Lua that is not trusted yet: %s"):format(
            vim.fn.fnamemodify(d.path, ":~:."),
            vim.fn.fnamemodify(path, ":~:.")
          )
      ),
      0
    )
  end
end

---Render a description (a template) in a task; `cb(err, text)` on the main loop.
function M.describe_async(fn, cb)
  require("dbdash.util.async").run(fn, function(err, text)
    vim.schedule(function()
      cb(err, text)
    end)
  end)
end

return M
