-- The view of a dashboard (ARCHITECTURE.md#drawing): its buffer and windows, the frames
-- that draw its document (restyle, layout, paint, composite) and the status line from the
-- document's data, and the UI side of starting and stopping it. The only entry from the
-- model is its document asking for a frame (Document.on_update); of the dashboards' events
-- the view follows dashboard:stopped (it closes the buffer).
local buffer = require("dbdash.view.buffer")
local W = require("dbdash.util.width")
local events = require("dbdash.dashboard.events")
local notifier = require("dbdash.view.notifier") -- it tells what the dashboards report

local M = {}

local function opts()
  return require("dbdash.options").current
end

local function now()
  vim.uv.update_time()
  return vim.uv.now()
end

---Countdown text: {time} the seconds left, {clock} m:ss (h:mm:ss from an hour);
---"…" while refreshing.
function M.countdown_text(fmt, secs, running)
  if running then
    return "…"
  end
  local f = math.floor
  local clock = secs >= 3600
      and ("%d:%02d:%02d"):format(f(secs / 3600), f(secs % 3600 / 60), secs % 60)
    or ("%d:%02d"):format(f(secs / 60), secs % 60)
  return (fmt:gsub("{time}", tostring(secs)):gsub("{clock}", clock))
end

---Seconds until `at` (loop time in ms), 0 without one.
local function remaining(at)
  if not at then
    return 0
  end
  return math.max(0, math.ceil((at - now()) / 1000))
end

---Style queries on an element of the dashboard's document (css.scope).
local function scope(node)
  return require("dbdash.css").scope(node, nil)
end

---Rendering update (Servo's "update the rendering"): restyle the document, lay it out
---(layout/view.lua), paint it (paint/) and composite the layers into lines (compositor/).
---@return string[] lines the header's
---@return table[] hl
---@return dbdash.compositor.Frame body
---@return integer offset the header's rows
---@return table[] regions the panels' (by panel index)
function M.render_view(d, width, height)
  d.doc.updating = true -- parts created while laying out need no frame of their own
  -- style phase: restyle from the dirty root before layout reads computed styles and
  -- decides what it can reuse
  d.last_restyle = require("dbdash.css.style").take_restyled(d.doc)
  local tree = require("dbdash.layout.view").reflow(d, width, height)
  local list = require("dbdash.paint").view(tree)
  local lines, hl = vim.deepcopy(list.header.lines), vim.deepcopy(list.header.hl)
  local offset = #lines
  local cells, outs = {}, {}
  for i, l in ipairs(list.layers) do
    cells[i] = { x = l.x, width = l.width, y = l.y, height = l.height }
    outs[i] = l.out
  end
  local body = require("dbdash.compositor").compose(cells, outs)
  local regions = {}
  for i, r in ipairs(body.regions) do
    regions[i] = { row_s = r.row_s + offset, row_e = r.row_e + offset, x = r.x, width = r.width }
  end
  -- where the statuses go (update_status): the header's line, each panel's title line
  local head = list.header.lines[1]
  d.header_slot = head
    and {
      row = 0,
      start = 0,
      from = W.width((head:gsub("%s+$", ""))) + (head:match("%S") and 1 or 0),
      to = width,
    }
  d.status_slots = {}
  for i, l in ipairs(list.layers) do
    local sl = l.out.status_slot
    d.status_slots[i] = sl
      and {
        row = l.y + sl.row + offset,
        start = l.x + sl.start,
        from = l.x + sl.from,
        to = l.x + sl.to,
      }
  end
  -- hit-test regions in buffer rows (events/)
  d.hits = {}
  for _, h in ipairs(list.hits or {}) do
    d.hits[#d.hits + 1] = {
      row_s = h.row_s + offset,
      row_e = h.row_e + offset,
      x = h.x,
      width = h.width,
      node = h.node,
    }
  end
  d.doc.updating = false
  d.doc:drawn()
  return lines, hl, body, offset, regions
end

---Ask for a rendering update (Servo: a task marks state dirty and the event loop runs
---"update the rendering" once): every request until it runs is one update, at most one
---every 20 ms. Only data of elements changed (the status): only the status line is drawn.
---User actions call redraw() directly.
function M.request_render(d)
  if d.render_pending then
    return
  end
  d.render_pending = true
  local since = vim.uv.now() - (d.last_render_at or 0)
  vim.defer_fn(function()
    d.render_pending = false
    if require("dbdash.dashboard").get(d.path) ~= d or not d.buf then
      return
    end
    if d.paused then
      d.render_skipped = true -- hidden: drawn when shown again (resume)
      return
    end
    if d.doc:needs_frame() then
      M.redraw(d)
    else
      M.update_status(d)
    end
  end, math.max(0, 20 - since))
end

---Re-render cached results into the buffer (no query).
function M.redraw(d)
  if not vim.api.nvim_buf_is_valid(d.buf) then
    return
  end
  local width, height = buffer.size(d.buf)
  d.last_size = { width, height }
  d.last_render_at = vim.uv.now()
  local lines, hl, body, offset, regions = M.render_view(d, width, height)
  d.regions = regions
  vim.list_extend(lines, body.lines)
  for _, h in ipairs(body.hl) do
    hl[#hl + 1] = {
      row = h.row + offset,
      col_s = h.col_s,
      col_e = h.col_e,
      group = h.group,
      priority = h.priority,
    }
  end
  if #lines == 0 then
    lines = { "" }
  end
  d.header_rows = offset
  buffer.draw(d.buf, lines, hl)
  vim.b[d.buf].dbdash_regions = d.regions
  M.update_status(d)
end

---A status `text` placed in `slot` (buffer row, window columns: `start` of the line,
---free cells `from` up to `to`) by setup countdown_position: "right_align" at the end of
---the free cells, "eol" at their start, "overlay" at the line's start. In the free cells
---it is cut with "…" when it does not fit, and left out without room: the title is
---content, the status gives way.
---@return dbdash.view.buffer.StatusMark?
local function place(slot, text, hl)
  if not (slot and text and text ~= "") then
    return nil
  end
  local position = opts().countdown_position
  if position == "overlay" then
    local room = slot.to - slot.start
    return { row = slot.row, col = slot.start, text = W.truncate(text, room, "…"), hl = hl }
  end
  local room = slot.to - slot.from
  if W.width(text) > room then
    if room < 2 then
      return nil
    end
    text = W.truncate(text, room, "…")
  end
  local col = position == "eol" and slot.from or slot.to - W.width(text)
  return { row = slot.row, col = col, text = text, hl = hl }
end

---The status line (extmarks) from the document's data (dashboard/commit.lua): the
---top-level countdown on the header line, each panel's status on its title line (its
---source's state, its countdown; "…" while it queries).
function M.update_status(d)
  d.doc.data_changed = false
  local hl = scope(d.header_node):hl("countdown")
  local marks = {}
  local hdata = d.header_node.data or {}
  local shown, format = require("dbdash.css").countdown(d.header_node)
  if shown and hdata.next_at then
    local text = M.countdown_text(format, remaining(hdata.next_at), hdata.refreshing)
    marks[#marks + 1] = place(d.header_slot, text, hl)
  end
  for i, p in ipairs(d.panels) do
    local data = p.node.data or {}
    local p_shown, p_format = require("dbdash.css").countdown(p.node)
    local text = (p_shown or data.running)
        and M.countdown_text(p_format, remaining(data.next_at), data.running)
      or nil
    if data.state then
      text = data.state .. (text and p_shown and data.state ~= "ended" and ("  " .. text) or "")
    end
    marks[#marks + 1] = place(d.status_slots and d.status_slots[i], text, hl)
  end
  buffer.set_status(d.buf, marks)
end

---The panel at buffer line `lnum` (1-based) and display column `dcol` (0-based): the node
---there (hit test, events/), then its panel.
function M.panel_at(d, lnum, dcol)
  local dom_events = require("dbdash.events")
  return dom_events.panel_of(d, dom_events.hit_test(d, lnum, dcol))
end

-- Starting and stopping (the UI's side) --------------------------------------------------

---@class dbdash.StartOpts
---@field tokens string[]? command-line name=value arguments
---@field ask_all boolean? prompt for every argument (:DbDashStart!)
---@field buf integer? buffer to adopt
---@field win integer? window to show the dashboard in (default: current, or `open`)
---@field open "current"|"vsplit"|"split"|"tab"|nil how to show it when no `win` is given
---@field no_show boolean? do not display the buffer

---Show `buf` in `win`; without a window, per `open` ("current" | "vsplit" | "split" |
---"tab", see setup({ dashboard = { open = ... } })). A dashboard already visible in a
---split (current tab) or a tab (any tab) is jumped to instead of opened again.
local function show_in(buf, win, open)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    open = open or "current"
    if open ~= "current" then
      local wins = open == "tab" and vim.fn.win_findbuf(buf)
        or vim.tbl_filter(function(w)
          return vim.api.nvim_win_get_buf(w) == buf
        end, vim.api.nvim_tabpage_list_wins(0))
      if wins[1] then
        vim.api.nvim_set_current_win(wins[1])
        return
      end
      vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tabnew" })[open])
      if open == "tab" then
        local scratch = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_buf(0, buf)
        if scratch ~= buf and vim.fn.bufname(scratch) == "" and not vim.bo[scratch].modified then
          -- (pcall: the scratch buffer may be gone already)
          pcall(vim.api.nvim_buf_delete, scratch, { force = true })
        end
      end
    end
    win = vim.api.nvim_get_current_win()
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_current_win(win)
end

---The countdown display: updated every countdown_interval while shown.
local function start_countdowns(d)
  if d.ctimer then
    return
  end
  d.ctimer = vim.uv.new_timer()
  local every = opts().countdown_interval
  d.ctimer:start(every, every, function()
    vim.schedule(function()
      if d.ctimer and not d.paused then
        M.update_status(d)
      end
    end)
  end)
end

local function stop_countdowns(d)
  if d.ctimer then
    d.ctimer:stop()
    if not d.ctimer:is_closing() then
      d.ctimer:close()
    end
    d.ctimer = nil
  end
end

---Show a created dashboard: its buffer, the frames of its document, its key actions.
local function attach(d, o)
  d.buf = buffer.create(d.path, o.buf)
  -- Deleting the buffer (:bdelete, :bwipeout) stops the dashboard.
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = d.buf,
    once = true,
    callback = function()
      require("dbdash.dashboard").stop(d.path, { keep_buffer = true })
    end,
  })
  -- a change of the document asks for a frame
  d.doc.on_update = function()
    M.request_render(d)
  end
  -- the dashboard keys are events at the cursor; reaching the root, they are actions of the
  -- dashboard (handled by commands.lua, see dbdash/init.lua)
  for action in pairs(buffer.ACTIONS) do
    d.doc.root:on(action, function(ev)
      events:emit("action", d, action, ev)
    end)
  end
  if not o.no_show then
    show_in(d.buf, o.win, o.open)
  end
  start_countdowns(d)
  M.redraw(d)
  vim.schedule(M.update_visibility) -- e.g. restored by a session into another tab
end

---Start a dashboard, or switch to it when it is already running.
---@param path string
---@param o dbdash.StartOpts?
function M.start(path, o)
  o = o or {}
  local dashboards = require("dbdash.dashboard")
  local args = require("dbdash.args")
  path = dashboards.normalize(path)
  local existing = dashboards.get(path)
  if existing then
    if o.tokens and #o.tokens > 0 then
      local ok, cli = pcall(args.parse_cli, existing.cfg.args, o.tokens)
      if not ok then
        return events:emit("dashboard:error", path, cli)
      end
      existing:set_cli(cli)
    end
    buffer.apply_keys(existing.buf)
    if not o.no_show then
      show_in(existing.buf, o.win, o.open)
    end
    return existing
  end
  local cfg, state, level = dashboards.prepare(path, o.tokens, function(answer)
    -- The decision made in the trust prompt's View float.
    local name = vim.fn.fnamemodify(path, ":~:.")
    if answer == "allow" then
      M.start(path, o)
    elseif answer == "deny" then
      notifier.warn(
        ("%s denied; it will not run (:DbDashTrust allow %s to allow it)"):format(name, name)
      )
    else
      notifier.info(("%s not started (not trusted yet)"):format(name))
    end
  end)
  if not cfg then
    if type(state) == "string" then
      notifier.notify(state, level or vim.log.levels.WARN)
    elseif state then
      events:emit("dashboard:error", path, state)
    end
    return
  end
  ---@cast state dbdash.ArgState (it started)
  local function launch()
    if dashboards.get(path) then -- started meanwhile (e.g. twice from the sidebar)
      return
    end
    local d = dashboards.create(path, cfg, state, require("dbdash.session").take_pending(path))
    attach(d, o)
  end
  local to_ask = o.ask_all and cfg.args or args.missing_required(cfg.args, state)
  if #to_ask == 0 then
    launch()
    return
  end
  require("dbdash.view.args_ui").ask_all(to_ask, state, function(done)
    if not done then
      if o.buf and vim.api.nvim_buf_is_valid(o.buf) then
        buffer.create(path, o.buf) -- keep the adopted buffer usable
      end
      return
    end
    local missing = args.missing_required(cfg.args, state)
    if #missing > 0 then
      return events:emit(
        "dashboard:error",
        path,
        require("dbdash.util.error").new({
          phase = "args",
          message = "missing required argument '" .. (missing[1].key or missing[1].name) .. "'",
        })
      )
    end
    launch()
  end)
end

---Stop a dashboard and close its buffer (o.keep_buffer: keep it).
---@param path string
---@param o { keep_buffer: boolean? }?
function M.stop(path, o)
  return require("dbdash.dashboard").stop(path, o)
end

---Close the buffer of a stopped dashboard; windows show the alternate buffer (or an empty
---one) instead.
local function close_buffer(d)
  if not (d.buf and vim.api.nvim_buf_is_valid(d.buf)) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(d.buf)) do
    vim.api.nvim_win_call(win, function()
      local alt = vim.fn.bufnr("#")
      if alt > 0 and alt ~= d.buf and vim.fn.buflisted(alt) == 1 then
        vim.cmd("buffer " .. alt)
      else
        vim.cmd("enew")
      end
    end)
  end
  -- (pcall: the buffer may be wiped already (:bwipeout started the stop))
  pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
end

---Pause dashboards that no window of the current tab page shows, resume the others
---(setup({ dashboard = { pause_hidden = true } }), the default).
function M.update_visibility()
  local pause_hidden = opts().dashboard.pause_hidden
  local shown = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    shown[vim.api.nvim_win_get_buf(w)] = true
  end
  for _, d in ipairs(require("dbdash.dashboard").list()) do
    if not pause_hidden or shown[d.buf] then
      if d.paused then
        d:resume()
        -- shown again: the countdowns, and the frame that waited (what was committed as
        -- it was shown: dashboard/commit.lua)
        start_countdowns(d)
        if d.render_skipped or d.doc:needs_frame() then
          d.render_skipped = false
          M.request_render(d)
        end
        M.update_status(d)
      end
    elseif not d.paused then
      d:pause()
      stop_countdowns(d)
    end
  end
end

---A window closes (WinClosed: it still shows its buffer). Closing the last window of a
---dashboard (:q, :close, :only, :tabclose) stops it like :DbDashStop; a dashboard that is
---only hidden (another buffer in its window, another tab page) pauses instead. Not while
---Neovim exits or a session loads (they close and recreate windows).
---@param win integer
function M.on_win_closed(win)
  if vim.v.exiting ~= vim.NIL or vim.g.SessionLoad == 1 then
    return
  end
  local dashboards = require("dbdash.dashboard")
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  local d = ok and dashboards.for_buf(buf)
  if not d then
    return
  end
  vim.schedule(function()
    if dashboards.get(d.path) ~= d or vim.v.exiting ~= vim.NIL or vim.g.SessionLoad == 1 then
      return
    end
    if vim.api.nvim_buf_is_valid(d.buf) and #vim.fn.win_findbuf(d.buf) == 0 then
      M.stop(d.path)
    end
  end)
end

---Redraw dashboards whose window size changed (uses cached data).
function M.on_resize()
  for _, d in ipairs(require("dbdash.dashboard").list()) do
    local w, h = buffer.size(d.buf)
    if not d.last_size or d.last_size[1] ~= w or d.last_size[2] ~= h then
      d.doc:note_reason("viewport") -- Servo: RestyleReason::ViewportChanged
      M.request_render(d)
    end
  end
end

---A dbdash://<path> buffer is read (:edit, a session): its running dashboard is drawn again
---(:edit cleared the buffer), else the dashboard starts in it.
---@param buf integer
---@param name string the buffer's name
function M.on_read(buf, name)
  local path = buffer.path_of(name)
  if not path then
    return
  end
  local d = require("dbdash.dashboard").get(path)
  if d and d.buf == buf then
    M.redraw(d)
  else
    M.start(path, { buf = buf, no_show = true })
  end
end

---Start dashboards for restored session buffers named dbdash://<path>.
function M.adopt_session_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local path = buffer.path_of(vim.api.nvim_buf_get_name(b))
    if path and vim.api.nvim_buf_is_loaded(b) and not require("dbdash.dashboard").get(path) then
      M.start(path, { buf = b, no_show = true })
    end
  end
end

---Neovim exits (VimLeavePre): the countdowns stop, and the dashboards (kept for session
---hooks that run later).
function M.on_exit()
  for _, d in ipairs(require("dbdash.dashboard").list()) do
    stop_countdowns(d)
  end
  require("dbdash.dashboard").freeze_all()
end

events:on("dashboard:stopped", function(d, o)
  stop_countdowns(d)
  if not o.keep_buffer then
    close_buffer(d)
  end
end)

return M
