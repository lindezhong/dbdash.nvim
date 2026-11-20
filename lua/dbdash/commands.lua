-- Command implementations (design §3.1) and completion.
local args = require("dbdash.args")
local sched = require("dbdash.scheduler")

local M = {}

local function err(msg)
  vim.notify("dbdash: " .. msg, vim.log.levels.ERROR)
end

---The dashboard for the current buffer; with exactly one running, that one.
---@return dbdash.Dashboard?
local function current()
  local d = sched.for_buf(vim.api.nvim_get_current_buf())
  if d then
    return d
  end
  local all = sched.list()
  if #all == 1 then
    return all[1]
  end
  err(#all == 0 and "no dashboard is running" or "not in a dbdash buffer")
end

local function short(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

---:DbDashStart[!] <config> [name=value ...]
function M.start(fargs, bang)
  if #fargs == 0 then
    return err("usage: DbDashStart <config.yaml> [name=value ...]")
  end
  local path = table.remove(fargs, 1)
  sched.start(path, { tokens = fargs, ask_all = bang })
end

function M.restart()
  local d = current()
  if d then
    d:restart()
  end
end

---:DbDashStop [config]
function M.stop(path)
  if path and path ~= "" then
    if not sched.stop(sched.normalize(path)) then
      err("not running: " .. path)
    end
    return
  end
  local d = current()
  if d then
    sched.stop(d.path)
  end
end

local function status_word(d)
  if d.running then
    return "running query"
  elseif d.error then
    return "error"
  end
  return "idle"
end

function M.list()
  local all = sched.list()
  if #all == 0 then
    vim.api.nvim_echo({ { "No dashboards running" } }, false, {})
    return
  end
  local chunks = { { "Running dashboards:\n", "Title" } }
  for _, d in ipairs(all) do
    chunks[#chunks + 1] = { ("  %s - %s, next refresh in %ds\n"):format(short(d.path), status_word(d), d:remaining()) }
  end
  vim.api.nvim_echo(chunks, false, {})
end

function M.status()
  local d = current()
  if not d then
    return
  end
  local url = require("dbdash.db.url")
  local lines = {
    "Config:    " .. short(d.path),
    "Database:  " .. d.cfg.database.type .. "  " .. url.redact(d.cfg.database.url),
    "Status:    " .. status_word(d),
    ("Interval:  %ds, next refresh in %ds"):format(d.cfg.show.interval / 1000, d:remaining()),
  }
  if d.error then
    lines[#lines + 1] = "Error:     " .. sched.format_error(d.error):gsub("\n", " ")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Recent queries:"
  if #d.history == 0 then
    lines[#lines + 1] = "  (none yet)"
  end
  for _, h in ipairs(d.history) do
    local when = os.date("%H:%M:%S", h.at)
    if h.skipped then
      lines[#lines + 1] = ("  %s  skipped (previous query still running)"):format(when)
    elseif h.error then
      lines[#lines + 1] = ("  %s  error: %s"):format(when, h.error:gsub("\n", " "))
    else
      lines[#lines + 1] = ("  %s  %6.0f ms  %d rows"):format(when, h.elapsed_ms or 0, h.rows or 0)
    end
  end
  require("dbdash.view.popup").open(lines, { title = "DbDash status" })
end

function M.browse()
  require("dbdash.view.sidebar").open()
end

function M.close()
  require("dbdash.view.sidebar").close()
end

function M.show_variables()
  local d = current()
  if not d then
    return
  end
  local specs = d.cfg.query.args
  if #specs == 0 then
    vim.api.nvim_echo({ { "This dashboard has no arguments" } }, false, {})
    return
  end
  local lines, hl = {}, {}
  for _, s in ipairs(specs) do
    local v = args.value(s, d.state)
    local line = ("%s = %s"):format(s.name, v == nil and "(unset)" or args.format_value(v))
    hl[#hl + 1] = { row = #lines, col_s = 0, col_e = #s.name, group = "DbDashArgName" }
    local extra = { s.type }
    if s.default ~= nil and not vim.deep_equal(s.default, v) then
      extra[#extra + 1] = "default " .. args.format_value(s.default)
    end
    if s.required then
      extra[#extra + 1] = "required"
    end
    line = line .. "    (" .. table.concat(extra, ", ") .. ")"
    if s.description then
      line = line .. "  " .. s.description
    end
    lines[#lines + 1] = line
  end
  require("dbdash.view.popup").open(lines, { title = "DbDash arguments", hl = hl })
end

function M.modify_variable()
  local d = current()
  if not d then
    return
  end
  local specs = d.cfg.query.args
  if #specs == 0 then
    return err("this dashboard has no arguments")
  end
  vim.ui.select(specs, {
    prompt = "Argument to modify",
    format_item = function(s)
      return ("%s = %s"):format(s.name, args.format_value(args.value(s, d.state)))
    end,
  }, function(spec)
    if not spec then
      return
    end
    require("dbdash.view.args_ui").ask(spec, args.value(spec, d.state), function(v)
      if v ~= nil and sched.get(d.path) == d then
        args.set_modified(d.state, spec.name, v)
        d:restart()
      end
    end)
  end)
end

---:DbDashUpdateVariable <name> <value>
function M.update_variable(name, value)
  local d = current()
  if not d then
    return
  end
  if not name or not value then
    return err("usage: DbDashUpdateVariable <name> <value>")
  end
  local spec = args.find(d.cfg.query.args, name)
  if not spec then
    return err("unknown argument '" .. name .. "'")
  end
  local ok, v = pcall(args.parse_value, spec, value)
  if not ok then
    return err(v.message or tostring(v))
  end
  args.set_modified(d.state, name, v)
  d:restart()
end

function M.reset_variables()
  local d = current()
  if d then
    args.reset(d.state)
    d:restart()
  end
end

function M.show_sql()
  local d = current()
  if not d then
    return
  end
  local sql = d.sql
  if not sql then
    local e
    sql, e = d:render_sql()
    if not sql then
      return err(sched.format_error(e))
    end
  end
  require("dbdash.view.popup").open(vim.split(sql, "\n", { plain = true }), {
    title = "DbDash query",
    filetype = d.cfg.database.type == "mongodb" and "json" or "sql",
  })
end

---:DbDashMksession[!] [file] / :Mksession: sessions record dbdash:// buffers by name.
function M.mksession(bang, file)
  vim.cmd("mksession" .. (bang and "!" or "") .. (file ~= "" and (" " .. vim.fn.fnameescape(file)) or ""))
end

---:DbDashStyle <type> <style> | canvas <name> | reset: re-render cached data (§11.4).
---Overrides last until the dashboard stops.
function M.style(fargs)
  local d = current()
  if not d then
    return
  end
  local registry = require("dbdash.render.registry")
  local a, b = fargs[1], fargs[2]
  if not a then
    local renderer, canvas = registry.resolve(d:show_config(), require("dbdash").options.styles)
    vim.api.nvim_echo({ { ("%s: renderer=%s canvas=%s"):format(d:show_config().type, renderer, canvas) } }, false, {})
    return
  end
  if a == "reset" then
    d.style = {}
  elseif a == "canvas" then
    if not b or not registry.get("canvas/" .. b) then
      return err("unknown canvas '" .. tostring(b) .. "' (available: " .. table.concat(registry.names("canvas/"), ", ") .. ")")
    end
    d.style.canvas = b
  else
    if not registry.DEFAULTS[a] and not registry.names("chart/" .. a .. "/")[1] then
      return err("unknown chart type '" .. a .. "'")
    end
    if a ~= d.cfg.show.type then
      d.style.type = a
    else
      d.style.type = nil
    end
    if b then
      if registry.get("chart/" .. a .. "/" .. b) then
        d.style.renderer = b
      elseif registry.get("canvas/" .. b) then
        d.style.renderer = "canvas"
        d.style.canvas = b
      else
        return err(("unknown style '%s' for %s (available: %s)"):format(
          b,
          a,
          table.concat(vim.list_extend(registry.names("chart/" .. a .. "/"), registry.names("canvas/")), ", ")
        ))
      end
    else
      d.style.renderer = nil
    end
  end
  d:redraw()
end

function M.complete_style(arglead, cmdline)
  local registry = require("dbdash.render.registry")
  local words = vim.split(cmdline:gsub("^%s*%S+%s*", ""), "%s+", { trimempty = true })
  local out
  if #words == 0 or (#words == 1 and arglead ~= "") then
    out = vim.tbl_keys(registry.DEFAULTS)
    vim.list_extend(out, { "canvas", "reset" })
  elseif words[1] == "canvas" then
    out = registry.names("canvas/")
  else
    out = registry.names("chart/" .. words[1] .. "/")
    if (registry.DEFAULTS[words[1]] or {}).canvas then
      vim.list_extend(out, registry.names("canvas/"))
    end
  end
  table.sort(out)
  return vim.tbl_filter(function(x)
    return vim.startswith(x, arglead)
  end, out)
end

-- Completion ------------------------------------------------------------------------------

local spec_cache = {}

local function specs_for(path)
  path = sched.normalize(path)
  local d = sched.get(path)
  if d then
    return d.cfg.query.args
  end
  local mtime = (vim.uv.fs_stat(path) or {}).mtime
  local c = spec_cache[path]
  if c and mtime and c.mtime == mtime.sec then
    return c.specs
  end
  local cfg = require("dbdash.config").load(path)
  local specs = cfg and cfg.query.args or {}
  spec_cache[path] = { mtime = mtime and mtime.sec, specs = specs }
  return specs
end

local function complete_args(specs, arglead)
  local out = {}
  local name, partial = arglead:match("^([%a_][%w_]*)=(.*)$")
  if name then
    local spec = args.find(specs, name)
    for _, c in ipairs(spec and spec.choices or {}) do
      local text = args.format_value(c)
      if vim.startswith(text, partial) then
        out[#out + 1] = name .. "=" .. text
      end
    end
    return out
  end
  for _, s in ipairs(specs) do
    if vim.startswith(s.name, arglead) then
      out[#out + 1] = s.name .. "="
    end
  end
  return out
end

---Completion for :DbDashStart: config files, then name= and choices.
function M.complete_start(arglead, cmdline)
  local words = vim.split(cmdline:gsub("^%s*%S+%s*", ""), "%s+", { trimempty = true })
  local typing_first = #words == 0 or (#words == 1 and arglead ~= "")
  if typing_first then
    local out = {}
    for _, f in ipairs(vim.fn.getcompletion(arglead, "file")) do
      if f:match("/$") or f:match("%.ya?ml$") then
        out[#out + 1] = f
      end
    end
    return out
  end
  local ok, specs = pcall(specs_for, words[1])
  return ok and complete_args(specs, arglead) or {}
end

function M.complete_running(arglead)
  local out = {}
  for _, d in ipairs(sched.list()) do
    local s = short(d.path)
    if vim.startswith(s, arglead) then
      out[#out + 1] = s
    end
  end
  return out
end

function M.complete_update(arglead, cmdline)
  local d = sched.for_buf(vim.api.nvim_get_current_buf()) or sched.list()[1]
  if not d then
    return {}
  end
  local words = vim.split(cmdline:gsub("^%s*%S+%s*", ""), "%s+", { trimempty = true })
  if #words == 0 or (#words == 1 and arglead ~= "") then
    local out = {}
    for _, s in ipairs(d.cfg.query.args) do
      if vim.startswith(s.name, arglead) then
        out[#out + 1] = s.name
      end
    end
    return out
  end
  local spec = args.find(d.cfg.query.args, words[1])
  local out = {}
  for _, c in ipairs(spec and spec.choices or {}) do
    local text = args.format_value(c)
    if vim.startswith(text, arglead) then
      out[#out + 1] = text
    end
  end
  return out
end

return M
