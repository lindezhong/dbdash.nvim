-- Events (after Servo's DocumentEventHandler and Event::dispatch): an input at a buffer
-- position is hit-tested against what painting recorded (each panel's region, and in it
-- the rows of its title, argument line and chart) to find the target node; the event then
-- runs the listeners along the path from the document root to the target (capture) and
-- back (bubble). Listeners are added with node:on(type, fn, { capture = true }).
local M = {}

---@class dbdash.events.Event
---@field type string
---@field target dbdash.dom.Node
---@field current dbdash.dom.Node? the node whose listener runs
---@field phase "capture"|"target"|"bubble"
---@field detail table?
---@field stopped boolean
local Event = {}
Event.__index = Event

function Event:stop_propagation()
  self.stopped = true
end

---The node at a buffer position of a dashboard (1-based line, 0-based display column):
---the innermost recorded region that contains it, else the document root.
---@return dbdash.dom.Node?
function M.hit_test(d, lnum, dcol)
  if not d.doc then
    return nil
  end
  local row, best, best_area = lnum - 1, nil, math.huge
  for _, r in ipairs(d.hits or {}) do
    if row >= r.row_s and row <= r.row_e and (dcol or 0) >= r.x and (dcol or 0) < r.x + r.width then
      local area = (r.row_e - r.row_s + 1) * r.width
      if area <= best_area then
        best, best_area = r.node, area
      end
    end
  end
  return best or d.doc.root
end

---Dispatch an event at `target`: capture listeners from the root down, the target's
---listeners, then bubble listeners up to the root, until one stops it.
---@return dbdash.events.Event
function M.dispatch(type, target, detail)
  local ev = setmetatable({ type = type, target = target, detail = detail, stopped = false }, Event)
  local path = target:ancestors() -- target first
  for k = #path, 2, -1 do -- capture: root .. parent
    local n = path[k]
    for _, l in ipairs(n.handlers and n.handlers[type] or {}) do
      if l.capture and not ev.stopped then
        ev.current, ev.phase = n, "capture"
        l.fn(ev)
      end
    end
  end
  for k = 1, #path do -- target, then bubble
    local n = path[k]
    for _, l in ipairs(n.handlers and n.handlers[type] or {}) do
      if (k == 1 or not l.capture) and not ev.stopped then
        ev.current, ev.phase = n, k == 1 and "target" or "bubble"
        l.fn(ev)
      end
    end
    if ev.stopped then
      break
    end
  end
  return ev
end

---An input at the cursor of the current window: hit test, then dispatch.
---@return dbdash.events.Event?
function M.at_cursor(d, type, detail)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local dcol = vim.fn.strdisplaywidth(line:sub(1, cursor[2]))
  local target = M.hit_test(d, cursor[1], dcol)
  if target then
    return M.dispatch(type, target, detail)
  end
end

---The panel of a node (its nearest panel ancestor), as the dashboard's Panel.
function M.panel_of(d, node)
  while node do
    if node.tag == "panel" then
      for _, p in ipairs(d.panels) do
        if p.node == node then
          return p
        end
      end
    end
    node = node.parent
  end
end

return M
