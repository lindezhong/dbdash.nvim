-- Command implementations (:help dbdash-commands) and completion.
local args = require("dbdash.args")
local sched = require("dbdash.dashboard")

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
  require("dbdash.view.dashboard").start(
    path,
    { tokens = fargs, ask_all = bang, open = require("dbdash.options").current.dashboard.open }
  )
end

function M.restart()
  local d = current()
  if d then
    d:restart()
  end
end

---:DbDashStop [config]
---:DbDashTrust [allow|deny|remove] [config]: decide for a config (default: the current
---dashboard's) without being asked; remove forgets the decision.
function M.trust(fargs)
  local action = fargs[1] or "allow"
  if not ({ allow = true, deny = true, remove = true })[action] then
    return err("usage: DbDashTrust [allow|deny|remove] [config.yaml]")
  end
  local path = fargs[2]
  if not path then
    local d = current()
    if not d then
      return
    end
    path = d.path
  end
  path = sched.normalize(path)
  local cfg, e = require("dbdash.config").load(path)
  if not cfg then
    return err(sched.format_error(e))
  end
  local trust = require("dbdash.trust")
  local files = trust.collect(path, cfg)
  trust.record(path, action, files)
  vim.notify(
    ("dbdash: %s %s"):format(
      vim.fn.fnamemodify(path, ":~:."),
      ({ allow = "trusted", deny = "denied", remove = "will be asked about again" })[action]
    )
  )
end

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

---Call fn(panel): the panel under the cursor in the dashboard window, the only panel, or
---one picked with vim.ui.select.
local function with_panel(d, fn)
  if #d.panels == 1 then
    return fn(d.panels[1])
  end
  if vim.api.nvim_get_current_buf() == d.buf then
    local cur = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local p = require("dbdash.view.dashboard").panel_at(
      d,
      cur[1],
      vim.fn.strdisplaywidth(line:sub(1, cur[2]))
    )
    if p then
      return fn(p)
    end
  end
  vim.ui.select(d.panels, {
    prompt = d.cfg.title and (d.cfg.title .. ": panel") or "Panel",
    format_item = function(p)
      return p:title()
    end,
  }, function(p)
    if p then
      fn(p)
    end
  end)
end
M.with_panel = with_panel

function M.list()
  local all = sched.list()
  if #all == 0 then
    vim.api.nvim_echo({ { "No dashboards running" } }, false, {})
    return
  end
  local chunks = { { "Running dashboards:\n", "Title" } }
  for _, d in ipairs(all) do
    chunks[#chunks + 1] =
      { ("  %s - %s, next refresh in %ds\n"):format(short(d.path), d:status_word(), d:remaining()) }
  end
  vim.api.nvim_echo(chunks, false, {})
end

function M.status()
  local d = current()
  if not d then
    return
  end
  local url = require("dbdash.db.url")
  local lines = {}
  if d.cfg.title then
    lines[#lines + 1] = "Title:     " .. d.cfg.title
  end
  vim.list_extend(lines, {
    "Config:    " .. short(d.path),
    "Status:    " .. d:status_word(),
  })
  if d.cfg.refresh_all then
    lines[#lines + 1] = ("Interval:  every panel refreshes every %ds, next in %ds"):format(
      d.cfg.refresh_all / 1000,
      d:remaining_global()
    )
  end
  for _, p in ipairs(d.panels) do
    lines[#lines + 1] = ""
    if d.cfg.grid then
      lines[#lines + 1] = ("Panel %d: %s"):format(p.index, p:title())
    end
    lines[#lines + 1] = "Database:  "
      .. p.cfg.database.type
      .. "  "
      .. url.redact(p.cfg.database.url)
    if p.push then
      local st = p.stream or { received = 0, processed = 0, dropped = 0, queue = {} }
      lines[#lines + 1] = ("Interval:  drawn every %ds, next in %ds"):format(
        p.cfg.show.interval / 1000,
        p:remaining()
      )
      lines[#lines + 1] = ("Push:      %s; %d received, %d processed, %d queued, %d dropped"):format(
        p:push_state(),
        st.received,
        st.processed,
        #st.queue,
        st.dropped
      )
      local h = st.handle
      if h and h.stats.truncated > 0 then
        lines[#lines + 1] = ("           %d item(s) cut at push.max_record"):format(
          h.stats.truncated
        )
      end
      local rejected = {}
      for code, n in pairs(h and h.stats.rejected or {}) do
        rejected[#rejected + 1] = ("%d x %d"):format(n, code)
      end
      if #rejected > 0 then
        table.sort(rejected)
        lines[#lines + 1] = "Rejected:  " .. table.concat(rejected, ", ")
      end
    else
      lines[#lines + 1] = ("Interval:  %ds, next refresh in %ds"):format(
        p.cfg.show.interval / 1000,
        p:remaining()
      )
    end
    if p.error then
      lines[#lines + 1] = "Error:     " .. sched.format_error(p.error):gsub("\n", " ")
    end
    if p.retry_at then
      lines[#lines + 1] = ("Retrying:  failed %d times in a row, next try in %ds (interval x%d)"):format(
        p.failures,
        p:remaining(),
        p.backoff_mult or 1
      )
    end
    lines[#lines + 1] = "Recent queries:"
    if #p.history == 0 then
      lines[#lines + 1] = "  (none yet)"
    end
    for _, h in ipairs(p.history) do
      local when = os.date("%H:%M:%S", h.at)
      if h.skipped then
        lines[#lines + 1] = ("  %s  skipped (previous query still running)"):format(when)
      elseif h.cancelled then
        lines[#lines + 1] = ("  %s  cancelled (%s)"):format(when, h.cancelled)
      elseif h.error then
        lines[#lines + 1] = ("  %s  error: %s"):format(when, h.error:gsub("\n", " "))
      else
        lines[#lines + 1] = ("  %s  %6.0f ms  %d rows"):format(when, h.elapsed_ms or 0, h.rows or 0)
      end
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
  local specs = d.cfg.args
  if #specs == 0 then
    vim.api.nvim_echo({ { "This dashboard has no arguments" } }, false, {})
    return
  end
  local lines, hl = {}, {}
  for _, s in ipairs(specs) do
    local v = args.value(s, d.state)
    local key = s.key or s.name
    local line = ("%s = %s"):format(key, v == nil and "(unset)" or args.format_value(v))
    local css = require("dbdash.css").scope(d.doc and d.doc.root or nil)
    hl[#hl + 1] = {
      row = #lines,
      col_s = 0,
      col_e = #key,
      group = css:hl("arg-name", { classes = s.panel and { "local" } or nil }),
    }
    local extra = { s.type } ---@type string[]
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
  local specs = d.cfg.args
  if #specs == 0 then
    return err("this dashboard has no arguments")
  end
  vim.ui.select(specs, {
    prompt = "Argument to modify",
    format_item = function(s)
      return ("%s = %s"):format(s.key or s.name, args.format_value(args.value(s, d.state)))
    end,
  }, function(spec)
    if not spec then
      return
    end
    require("dbdash.view.args_ui").ask(spec, args.value(spec, d.state), function(v)
      if v ~= nil and sched.get(d.path) == d then
        d:set_arg(spec.key or spec.name, v)
      end
    end)
  end)
end

---:DbDashUpdateVariable <name> <value>: a bare name sets every argument of that name
---(shared and local); <panel>.name only that panel's local one.
function M.update_variable(name, value)
  local d = current()
  if not d then
    return
  end
  if not name or not value then
    return err("usage: DbDashUpdateVariable <name> <value>")
  end
  local ok, values = pcall(args.parse_cli, d.cfg.args, { name .. "=" .. value })
  if not ok then
    return err(values.message or tostring(values))
  end
  d:set_args(values)
end

function M.reset_variables()
  local d = current()
  if d then
    d:reset_args()
  end
end

---:DbDashExport[!] [{format}] [{file}]: the result of the panel under the cursor as csv,
---tsv, json or markdown, into a register (default: unnamed, or "x:DbDashExport) or a file
---(overwritten only with !). Without a format, one is picked with vim.ui.select.
---@param fargs string[]
---@param bang boolean?
---@param reg string? register given with "x
function M.export(fargs, bang, reg)
  local d = current()
  if not d then
    return
  end
  fargs = fargs or {}
  local export = require("dbdash.export")
  local function run(fmt)
    if not vim.tbl_contains(export.FORMATS, fmt) then
      return err(
        ("unknown export format %q (use %s)"):format(fmt, table.concat(export.FORMATS, ", "))
      )
    end
    with_panel(d, function(p)
      if not p.rs then
        return err(
          "nothing to export yet: " .. (p.error and sched.format_error(p.error) or "no result")
        )
      end
      local out = export.format(p.rs, fmt)
      local what = ("%d rows as %s"):format(p.rs.row_count, fmt)
      local file = fargs[2]
      if file then
        file = vim.fn.fnamemodify(vim.fn.expand(file), ":p")
        if vim.uv.fs_stat(file) and not bang then
          return err(file .. " exists (add ! to overwrite)")
        end
        local f, ferr = io.open(file, "wb")
        if not f then
          return err("cannot write " .. file .. ": " .. tostring(ferr))
        end
        f:write(out)
        f:close()
        vim.notify(("dbdash: exported %s to %s"):format(what, vim.fn.fnamemodify(file, ":~:.")))
      else
        reg = (reg and reg ~= "") and reg or '"'
        vim.fn.setreg(reg, out, "l")
        vim.notify(("dbdash: exported %s to register %s"):format(what, reg))
      end
    end)
  end
  if fargs[1] then
    return run(fargs[1])
  end
  vim.ui.select(export.FORMATS, { prompt = "Export format" }, function(fmt)
    if fmt then
      run(fmt)
    end
  end)
end

---Completion for :DbDashExport: a format, then a file.
function M.complete_export(arglead, cmdline)
  local words = vim.split(cmdline:gsub("^%s*%S+%s*", ""), "%s+", { trimempty = true })
  if #words == 0 or (#words == 1 and arglead ~= "") then
    return vim.tbl_filter(function(f)
      return vim.startswith(f, arglead)
    end, require("dbdash.export").FORMATS)
  end
  return vim.fn.getcompletion(arglead, "file")
end

function M.show_sql()
  local d = current()
  if not d then
    return
  end
  with_panel(d, function(p)
    local function show(sql, code)
      local lines = vim.split(sql, "\n", { plain = true })
      if code then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "-- query.transform"
        vim.list_extend(lines, vim.split(code, "\n", { plain = true }))
      end
      require("dbdash.view.popup").open(lines, {
        title = d.cfg.grid and ("DbDash query: " .. p:title()) or "DbDash query",
        filetype = ({ mongodb = "json", http = "json", lua = "lua" })[p.cfg.database.type] or "sql",
      })
    end
    if p.sql then
      return show(p.sql, p.transform_code)
    end
    p:render_async(function(e, sql, code)
      if e then
        return err(sched.format_error(e))
      end
      show(sql, code)
    end)
  end)
end

---:DbDashDescribe: the description (template, shown as Markdown) of the dashboard (cursor
---on the header) or of the panel under the cursor; a one-chart dashboard shows both. Outside
---the dashboard window, a picker among those with one.
function M.describe()
  local d = current()
  if not d then
    return
  end
  local cfg = d.cfg
  local function show(parts)
    if #parts == 0 then
      return vim.notify("dbdash: no description", vim.log.levels.WARN)
    end
    local texts, i = {}, 0
    local function next_part()
      i = i + 1
      local part = parts[i]
      if not part then
        local title = #parts == 1 and parts[1].name
          or (cfg.title or vim.fn.fnamemodify(d.path, ":t"))
        local text = table.concat(texts, "\n\n")
        return require("dbdash.view.popup").open(vim.split(text, "\n", { plain = true }), {
          title = "DbDash: " .. title,
          markdown = true,
        })
      end
      part.render(function(e, text)
        if e then
          return err(sched.format_error(e))
        end
        text = text:gsub("%s+$", "")
        texts[#texts + 1] = #parts > 1 and ("## " .. part.name .. "\n\n" .. text) or text
        next_part()
      end)
    end
    next_part()
  end
  local function dashboard_part()
    return cfg.description
        and {
          name = cfg.title or "Dashboard",
          render = function(cb)
            d:describe_async(cb)
          end,
        }
      or nil
  end
  local function panel_part(p)
    return p.cfg.show.description
        and {
          name = p:title(),
          render = function(cb)
            p:describe_async(cb)
          end,
        }
      or nil
  end
  if not cfg.grid then
    return show(vim.tbl_filter(function(x)
      return x ~= nil
    end, { dashboard_part(), panel_part(d.panels[1]) }))
  end
  if vim.api.nvim_get_current_buf() == d.buf then
    local cur = vim.api.nvim_win_get_cursor(0)
    if cur[1] <= (d.header_rows or 0) then
      return show({ dashboard_part() })
    end
    local line = vim.api.nvim_get_current_line()
    local p = require("dbdash.view.dashboard").panel_at(
      d,
      cur[1],
      vim.fn.strdisplaywidth(line:sub(1, cur[2]))
    )
    if p then
      return show({ panel_part(p) })
    end
  end
  local items = {}
  if cfg.description then
    items[#items + 1] = dashboard_part()
  end
  for _, p in ipairs(d.panels) do
    items[#items + 1] = panel_part(p)
  end
  if #items == 0 then
    return show({})
  end
  vim.ui.select(items, {
    prompt = "Description of",
    format_item = function(x)
      return x.name
    end,
  }, function(x)
    if x then
      show({ x })
    end
  end)
end

---:DbDashMksession[!] [file] / :Mksession: sessions record dbdash:// buffers by name.
function M.mksession(bang, file)
  vim.cmd(
    "mksession" .. (bang and "!" or "") .. (file ~= "" and (" " .. vim.fn.fnameescape(file)) or "")
  )
end

---A :DbDashStyle value: JSON (numbers, true / false, lists, quoted strings), else the
---word itself.
local function style_value(text)
  local ok, v = pcall(vim.json.decode, text)
  if ok and v ~= vim.NIL then
    return v
  end
  return text
end

---Install a dashboard's runtime rules (:DbDashStyle): the dashboard-wide sheet and each
---panel's own (scoped to the panel), above every other origin.
local function apply_runtime(d)
  local parser = require("dbdash.css.parser")
  local function sheet(m)
    local rules, perr = parser.sheet(m.rules, m.order)
    if not rules then
      return nil, perr
    end
    return rules
  end
  local rules, perr = sheet(d.runtime_style)
  if not rules then
    return perr
  end
  d.doc:set_sheet("runtime", rules)
  for _, p in ipairs(d.panels) do
    if p.runtime_style then
      local pr, pe = sheet(p.runtime_style)
      if not pr then
        return pe
      end
      d.doc:set_sheet("runtime", pr, p.node)
    end
  end
end

---Add a declaration to a runtime sheet ({ rules = selector -> decls, order = selectors }).
local function declare(m, selector, prop, value)
  if not m.rules[selector] then
    m.rules[selector] = {}
    m.order[#m.order + 1] = selector
  end
  m.rules[selector][prop] = value
end

local function new_sheet()
  return { rules = {}, order = {} }
end

---:DbDashStyle, the dashboard's runtime style (like editing styles in DevTools):
---  :DbDashStyle                               the panel's renderer and canvas
---  :DbDashStyle <type> [<renderer|canvas>]    show the panel as another chart type
---  :DbDashStyle canvas <name>                 the panel's canvas
---  :DbDashStyle set <selector> <property> <value>   a rule for the whole dashboard
---  :DbDashStyle reset                         drop the runtime rules and type
---Renderer and canvas are rules on the panel's chart element (runtime origin, scoped to the
---panel); they last until the dashboard stops.
function M.style(fargs)
  local d = current()
  if not d then
    return
  end
  local registry = require("dbdash.render.registry")
  local a, b = fargs[1], fargs[2]
  d.runtime_style = d.runtime_style or new_sheet()
  if a == "set" then
    if #fargs < 4 then
      return err("usage: DbDashStyle set <selector> <property> <value>")
    end
    local value = style_value(table.concat(fargs, " ", 4))
    local saved = vim.deepcopy(d.runtime_style)
    declare(d.runtime_style, fargs[2], fargs[3], value)
    local perr = apply_runtime(d)
    if perr then
      d.runtime_style = saved
      apply_runtime(d)
      return err(
        ("%s%s: %s"):format(perr.key, perr.property and (" " .. perr.property) or "", perr.message)
      )
    end
    d:commit()
    return require("dbdash.view.dashboard").redraw(d)
  end
  if a == "reset" then
    d.runtime_style = new_sheet()
    for _, p in ipairs(d.panels) do
      p.runtime_style, p.style = nil, {}
      if p.node then
        d.doc:set_sheet("runtime", {}, p.node)
      end
    end
    d.doc:set_sheet("runtime", {})
    d:commit()
    return require("dbdash.view.dashboard").redraw(d)
  end
  with_panel(d, function(p)
    if not a then
      local chart = require("dbdash.css.style").get(p.chart_node)
      local renderer, canvas = registry.resolve(p:show_config().type, chart)
      vim.api.nvim_echo(
        { { ("%s: renderer=%s canvas=%s"):format(p:show_config().type, renderer, canvas) } },
        false,
        {}
      )
      return
    end
    p.runtime_style = p.runtime_style or new_sheet()
    if a == "canvas" then
      if not b or not registry.get("canvas/" .. b) then
        return err(
          "unknown canvas '"
            .. tostring(b)
            .. "' (available: "
            .. table.concat(registry.names("canvas/"), ", ")
            .. ")"
        )
      end
      declare(p.runtime_style, "chart", "canvas", b)
    else
      if not registry.DEFAULTS[a] and not registry.names("chart/" .. a .. "/")[1] then
        return err("unknown chart type '" .. a .. "'")
      end
      p.style.type = a ~= p.cfg.show.type and a or nil
      if b then
        if registry.get("chart/" .. a .. "/" .. b) then
          declare(p.runtime_style, "chart", "renderer", b)
        elseif registry.get("canvas/" .. b) then
          declare(p.runtime_style, "chart", "renderer", "canvas")
          declare(p.runtime_style, "chart", "canvas", b)
        else
          return err(
            ("unknown style '%s' for %s (available: %s)"):format(
              b,
              a,
              table.concat(
                vim.list_extend(registry.names("chart/" .. a .. "/"), registry.names("canvas/")),
                ", "
              )
            )
          )
        end
      elseif p.runtime_style.rules.chart then
        p.runtime_style.rules.chart.renderer = nil
      end
    end
    apply_runtime(d)
    d:commit()
    require("dbdash.view.dashboard").redraw(d)
  end)
end

---:DbDashInspect [element]: the element under the cursor (or an element inside it), its
---matching rules, computed style and box (DevTools).
function M.inspect(fargs)
  local d = current()
  if not d then
    return
  end
  return require("dbdash.inspect").open(d, fargs[1])
end

function M.complete_inspect(arglead)
  return vim.tbl_filter(function(x)
    return vim.startswith(x, arglead)
  end, require("dbdash.inspect").tags(sched.for_buf(vim.api.nvim_get_current_buf())))
end

function M.complete_style(arglead, cmdline)
  local registry = require("dbdash.render.registry")
  local words = vim.split(cmdline:gsub("^%s*%S+%s*", ""), "%s+", { trimempty = true })
  local out
  if #words == 0 or (#words == 1 and arglead ~= "") then
    out = vim.tbl_keys(registry.DEFAULTS)
    vim.list_extend(out, { "canvas", "reset", "set" })
  elseif words[1] == "set" then
    out = (#words == 2 and arglead == "" or #words == 3 and arglead ~= "")
        and require("dbdash.css.properties").names()
      or {}
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
    return d.cfg.args
  end
  local mtime = (vim.uv.fs_stat(path) or {}).mtime
  local c = spec_cache[path]
  if c and mtime and c.mtime == mtime.sec then
    return c.specs
  end
  local cfg = require("dbdash.config").load(path)
  local specs = cfg and cfg.args or {}
  spec_cache[path] = { mtime = mtime and mtime.sec, specs = specs }
  return specs
end

local function complete_args(specs, arglead)
  local out = {}
  local name, partial = arglead:match("^([%w_.]+)=(.*)$")
  if name then
    local spec = args.match(specs, name)[1]
    for _, c in ipairs(spec and spec.choices or {}) do
      local text = args.format_value(c)
      if vim.startswith(text, partial) then
        out[#out + 1] = name .. "=" .. text
      end
    end
    return out
  end
  for _, k in ipairs(args.keys(specs)) do
    if vim.startswith(k, arglead) then
      out[#out + 1] = k .. "="
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
    for _, k in ipairs(args.keys(d.cfg.args)) do
      if vim.startswith(k, arglead) then
        out[#out + 1] = k
      end
    end
    return out
  end
  local spec = args.match(d.cfg.args, words[1])[1]
  local out = {}
  for _, c in ipairs(spec and spec.choices or {}) do
    local text = args.format_value(c)
    if vim.startswith(text, arglead) then
      out[#out + 1] = text
    end
  end
  return out
end

---A dashboard key's action (an event that reached the document's root): its command.
function M.action(_, action, ev)
  if action == "export" then
    M.export({}, false, ev.detail and ev.detail.register) -- "xe: register x
  else
    M[require("dbdash.view.buffer").ACTIONS[action][1]]()
  end
end

return M
