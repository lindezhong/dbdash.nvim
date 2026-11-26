-- Runs of a panel's pipeline (refreshes and dbdash.run() callbacks) with their records,
local M = require("dbdash.scheduler")
local S = require("dbdash.scheduler.shared")
local Panel, Dashboard = S.Panel, S.Dashboard
local opts, now = S.opts, S.now
local args = require("dbdash.args")
local config = require("dbdash.config")
local db = require("dbdash.db")
local template = require("dbdash.template")
local W = require("dbdash.util.width")

---Render query.sql and query.transform for the current arguments: one template path for
---both (same variables, imports and helpers); the transform is Lua, so never autoescaped.
---Runs inside a util.async task (template Lua may wait on dbdash.* helpers); raises a
---template or database error.
---@return string sql, string? transform_code
---@param run dbdash.Run
function Panel:render_templates(run)
  local q = self.cfg.query
  local o = self:template_opts(run)
  local sql = M.render_text(self.d, q.sql, q.sql_line, vim.tbl_extend("force", o, { autoescape = q.autoescape }))
  local code = q.transform and M.render_text(self.d, q.transform, q.transform_line, o) or nil
  return sql, code
end

---The options of M.render_text for the templates of `run` (and its `meta`, set on it).
function Panel:template_opts(run)
  local q = self.cfg.query
  run.meta = require("dbdash.metadata").values(self, run) -- `meta` of templates and Lua
  if run.depth == 0 then
    self.meta = run.meta
  end
  return {
    dialect = db.driver(self.cfg.database.type).dialect,
    specs = self.cfg.visible_args,
    values = run.args,
    meta = run.meta,
    lua = run.lua,
    run = run,
    set_arg = function(name, v)
      self:set_arg(run, name, v)
    end,
    timeout = q.timeout,
    cancel = run.life.cancel,
    on_allow = function()
      self:refresh({ queue = true })
    end,
  }
end

---@class dbdash.Run one run of a panel's pipeline: a refresh (depth 0) or a callback
---@field values table<string, any> the arguments by name
---@field args table what Lua code sees as `args`
---@field depth integer 0 for a refresh, n for a callback n levels deep (meta.run.depth)
---@field counter { n: integer, runs: table[], cancel: dbdash.db.CancelToken } the refresh's
---  life: dbdash.run() calls so far, the run records (meta.runs) and the token that cancels
---  the refresh, shared by its callbacks (= run.life)
---@field record table this run's record (meta.run): id, kind, depth, parent_id, refresh_id,
---  args, started_at, finished_at, elapsed_ms, ok, error, sql, query, result
---@field lua { store: table, helpers: table } globals of all Lua code of the run
---@field meta table? the metadata of this run

---A run of the panel's pipeline with `values` (default: the current arguments).
---@param parent dbdash.Run? the run this one is a callback of
---@return dbdash.Run
---@param kind "refresh"|"callback"|"push"|"render"? render: :DbDashShowSQL and descriptions
---  (not a run of the life); push: an item of a push source; default refresh, or callback
---  with a parent
function Panel:new_run(values, parent, kind)
  local run = {
    values = values or args.resolve_panel(self.cfg, self.d.state),
    depth = parent and parent.depth + 1 or 0,
    -- The life: callbacks so far, records, and the cancel token of the refresh.
    counter = parent and parent.counter or { n = 0, runs = {}, version = 0, cancel = require("dbdash.db.cancel").new() },
    item = parent and parent.item or nil, -- push sources: the item a callback works on too
  }
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
  run.args = run.values -- Lua code sees (and may assign) the values; see Panel:sync_args
  run.seen = vim.deepcopy(run.values)
  run.lua = {
    store = self.store,
    helpers = self:helpers(run),
    after = function()
      self:sync_args(run)
    end,
  }
  return run
end

---After Lua code ran (a {% lua %} block, a module, query.transform, lua://): apply the
---arguments it assigned (`args.x = v`) with Panel:set_arg. An invalid one is put back
---and raises.
---@param run dbdash.Run
function Panel:sync_args(run)
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
      self:set_arg(run, name, v)
    end
  end
end

---Assign argument `name` in a run (Lua `args.x = v`, {% set args.x = v %}): checked, then
---seen by the rest of the run (its templates, transform, lua://) and kept like an edit in
---the dashboard (from the next refresh on; a local argument shadows a shared one). A
---callback's run keeps its own values: the caller's do not change. Raises a message.
---@param run dbdash.Run
function Panel:set_arg(run, name, v)
  if run.read_only then
    error("arguments cannot be assigned in a description", 0)
  end
  local spec = type(name) == "string" and self:arg_spec(name)
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
  args.set_modified(self.d.state, spec.key, v == nil and vim.NIL or v)
end



---A visible argument of the panel by name (a local one shadows a shared one).
function Panel:arg_spec(name)
  for _, spec in ipairs(self.cfg.visible_args) do
    if spec.name == name then
      return spec
    end
  end
end

---The `dbdash` table of a run's Lua code: the shared helpers plus the run's own:
---dbdash.run(args) runs the panel's pipeline again with `args` merged over the run's
---arguments (a callback: meta.run.kind is "callback", meta.run.depth its depth) and returns
---its rows as Lua data.
function Panel:helpers(run)
  local own = {
    run = function(over)
      if over ~= nil and type(over) ~= "table" then
        error(("dbdash.run: expected a table of arguments, got %s"):format(type(over)), 2)
      end
      local limits = opts().lua
      if run.counter.n + 1 > limits.max_callbacks then
        error(("dbdash.run: more than %d callbacks in one refresh (lua.max_callbacks)"):format(limits.max_callbacks), 2)
      end
      if run.depth + 1 > limits.max_callback_depth then
        error(("dbdash.run: callbacks nested deeper than %d (lua.max_callback_depth)"):format(limits.max_callback_depth), 2)
      end
      local values = {}
      for k, v in pairs(run.values) do
        values[k] = v
      end
      for name, v in pairs(over or {}) do
        local spec = type(name) == "string" and self:arg_spec(name)
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
      local child = self:new_run(values, run)
      local ok, err = pcall(self.pipeline, self, child)
      self:finish_record(child, not ok and err or nil)
      if not ok then
        error(err, 0)
      end
      return child.record.result
    end,
  }
  return setmetatable(own, { __index = require("dbdash.db.lua_env").helpers })
end

---Render template `text` (at `line` of the config) of dashboard `d`. Templates see exactly
---two names: args.<name> (o.specs with o.values) and meta.<name> (o.meta); imported
---templates and Lua in templates too. Inside a util.async task; raises template errors.
---@param o { dialect: table?, autoescape: boolean?, specs: dbdash.ArgSpec[], values: table, meta: table, lua: table?, timeout: integer?, cancel: dbdash.db.CancelToken?, on_allow: fun()? }
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
  local vars = { args = R.freeze(args_map, "args"), meta = R.freeze(metadata.for_template(o.meta), "meta") }
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
    helpers = o.lua and o.lua.helpers,
    after = o.lua and o.lua.after,
  }
  env.timeout = o.timeout or require("dbdash").default_ms("timeout")
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

---Render a description (a template) in a task; `cb(err, text)` on the main loop.
local function describe_async(fn, cb)
  require("dbdash.util.async").run(fn, function(err, text)
    vim.schedule(function()
      cb(err, text)
    end)
  end)
end

---The panel's show.description rendered with its arguments and metadata (Markdown).
function Panel:describe_async(cb)
  local show = self.cfg.show
  describe_async(function()
    local run = self:new_run(nil, nil, "render")
    run.read_only = true -- showing a description does not change arguments
    return M.render_text(self.d, show.description, show.description_line, {
      dialect = db.driver(self.cfg.database.type).dialect,
      specs = self.cfg.visible_args,
      values = run.args,
      meta = require("dbdash.metadata").values(self, run),
      lua = run.lua,
      set_arg = function(name, v)
        self:set_arg(run, name, v)
      end,
      timeout = self.cfg.query.timeout,
    })
  end, cb)
end

---The dashboard's description rendered with the shared arguments and the metadata
---outside any panel (db_* of the top-level database).
function Dashboard:describe_async(cb)
  local cfg = self.cfg
  describe_async(function()
    local values = args.resolve(cfg.shared_args, self.state)
    local seen = vim.deepcopy(values)
    local function refuse()
      error("arguments cannot be assigned in a description", 0)
    end
    return M.render_text(self, cfg.description, cfg.description_line, {
      dialect = cfg.database and db.driver(cfg.database.type).dialect or nil,
      specs = cfg.shared_args,
      values = values,
      meta = require("dbdash.metadata").dashboard_values(self),
      lua = {
        -- showing a description does not change arguments
        after = function()
          if not vim.deep_equal(values, seen) then
            refuse()
          end
        end,
      },
      set_arg = refuse,
    })
  end, cb)
end

---A file with Lua loaded while rendering (an imported .lua module or template with a
---{% lua %} block) must be covered by the config's trust. One that is not (imported
---through a computed path, or changed since the dashboard started) asks again, with all
---the config's files; allowing it from the View float refreshes the panel.
function Panel:check_file(path, text, kind)
  M.check_file(self.d, path, text, kind, function()
    self:refresh({ queue = true })
  end)
end

---check_file for any template of dashboard `d`; `on_allow` runs when it is allowed then.
function M.check_file(d, path, text, kind, on_allow)
  local trust = require("dbdash.trust")
  if kind == "template" and not trust.has_lua_block(text) then
    return
  end
  if not M.trust_required(d.path) or trust.covers(d.path, path, text) then
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
    error(require("dbdash.template.errors").new(
      "trust",
      why or ("%s runs Lua that is not trusted yet: %s"):format(
        vim.fn.fnamemodify(d.path, ":~:."),
        vim.fn.fnamemodify(path, ":~:.")
      )
    ), 0)
  end
end

---Render the templates in a task; `cb(err, sql, transform_code)` on the main loop.
function Panel:render_async(cb)
  require("dbdash.util.async").run(function()
    return self:render_templates(self:new_run(nil, nil, "render"))
  end, function(err, sql, code)
    vim.schedule(function()
      if not err then
        self.sql, self.transform_code = sql, code
      end
      cb(err, sql, code)
    end)
  end)
end
