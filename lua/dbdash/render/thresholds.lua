-- Thresholds on values: show.thresholds for stat charts, column_list[].thresholds for
-- tables, show.row_thresholds for table rows. A list of { value, class, notify? } steps; a
-- value at or above a step's value (at or below with thresholds_below) reaches it, and the
-- most severe step reached wins. The step's class goes on the element (value, cell, row)
-- and style sheets color it: the UA sheet colors success, info, warning and danger.
local M = {}

local nn = require("dbdash.util.null").nn

---Steps ordered from least to most severe.
---@param list table[]?
---@param below boolean?
---@return { value: number, class: string?, notify: boolean }[]
function M.steps(list, below)
  local out = {}
  for _, s in ipairs(nn(list) or {}) do
    local v = tonumber(nn(s.value))
    if v then
      out[#out + 1] = { value = v, class = nn(s.class), notify = nn(s.notify) == true }
    end
  end
  table.sort(out, function(a, b)
    if below then
      return a.value > b.value
    end
    return a.value < b.value
  end)
  return out
end

---Numeric value of a cell, or nil.
function M.number(v)
  if type(v) == "number" then
    return v
  elseif type(v) == "cdata" then
    return tonumber(v)
  elseif type(v) == "string" then
    return tonumber(v)
  end
end

---Severity level reached by `v` (0 = none) and its step.
---@param v any
---@param steps table[] from M.steps
---@param below boolean?
---@return integer level, table? step
function M.level(v, steps, below)
  local n = M.number(v)
  if not n then
    return 0
  end
  local level, step = 0, nil
  for i, s in ipairs(steps) do
    if (below and n <= s.value) or (not below and n >= s.value) then
      level, step = i, s
    end
  end
  return level, step
end

---The classes a step puts on an element ({} when none is reached).
function M.classes(step)
  return step and step.class and { step.class } or {}
end

---Validate a thresholds list from a config; returns an error message or nil.
function M.check(list)
  if not vim.islist(list) then
    return "thresholds must be a list of { value, class, notify }"
  end
  for i, s in ipairs(list) do
    if type(s) ~= "table" or tonumber(nn(s.value)) == nil then
      return ("thresholds[%d]: value must be a number"):format(i - 1)
    end
    if nn(s.color) ~= nil then
      return ('thresholds[%d]: color is appearance: give the step a class and color it in style (e.g. class: danger, or "value.danger": { color: ... })'):format(
        i - 1
      )
    end
    if
      nn(s.class) ~= nil and (type(s.class) ~= "string" or not s.class:match("^[%a_][%w_-]*$"))
    then
      return ("thresholds[%d]: class must be a class name"):format(i - 1)
    end
    if nn(s.notify) ~= nil and type(s.notify) ~= "boolean" then
      return ("thresholds[%d]: notify must be true or false"):format(i - 1)
    end
  end
end

---Levels for a panel's result, keyed by source: "value" for stat charts, the column name
---for table columns with thresholds. Each entry: { level, step, value, below, column }.
---@return table<string, table>
function M.levels(rs, show)
  local out = {}
  if show.type == "stat" and nn(show.thresholds) then
    local below = nn(show.thresholds_below) == true
    local steps = M.steps(show.thresholds, below)
    local v = require("dbdash.render.charts.stat.common").value(rs, show)
    local level, step = M.level(v, steps, below)
    out.value = { level = level, step = step, value = v, below = below }
  elseif show.type == "table" then
    for _, spec in ipairs(nn(show.column_list) or {}) do
      if type(spec) == "table" and nn(spec.thresholds) and nn(spec.column) then
        local below = nn(spec.thresholds_below) == true
        local steps = M.steps(spec.thresholds, below)
        local idx = rs:col_index(spec.column)
        local best = { level = 0, below = below, column = spec.column }
        for _, row in ipairs(idx and rs.rows or {}) do
          local level, step = M.level(row[idx], steps, below)
          if level > best.level then
            best =
              { level = level, step = step, value = row[idx], below = below, column = spec.column }
          end
        end
        out[spec.column] = best
      end
    end
  end
  return out
end

-- The rules of a config's thresholds (config/validators.lua): show.thresholds and those of
-- show.column_list entries.
M.validators = {
  {
    field = "show",
    validate = function(show, ctx, path)
      if nn(show.thresholds) ~= nil then
        local err = M.check(show.thresholds)
        if err then
          ctx:fail(path .. ".thresholds", "%s", err)
        end
      end
      for i, spec in ipairs(nn(show.column_list) or {}) do
        if type(spec) == "table" and nn(spec.thresholds) ~= nil then
          local err = M.check(spec.thresholds)
          if err then
            ctx:fail(("%s.column_list[%d].thresholds"):format(path, i - 1), "%s", err)
          end
        end
      end
    end,
  },
}

return M
