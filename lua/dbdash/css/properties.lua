-- CSS property registry (after Stylo's longhand definitions): for every property its name,
-- whether it is inherited, its initial value, how a declared value is parsed, and the
-- damage a change of its computed value causes (servo_restyle_damage):
--   repaint   only colors and glyph attributes change: paint again
--   relayout  sizes or positions may change: lay out again
--   rebuild   the boxes themselves change (another renderer, display): rebuild them
local M = {}

M.DAMAGE = { none = 0, repaint = 1, relayout = 2, rebuild = 3 }

local function nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

local function enum(...)
  local ok = {}
  for _, v in ipairs({ ... }) do
    ok[v] = true
  end
  local list = table.concat({ ... }, ", ")
  return function(v)
    if type(v) == "string" and ok[v] then
      return v
    end
    return nil, ("expected one of %s"):format(list)
  end
end

local function string_value(v)
  if type(v) == "string" then
    return v
  end
  return nil, "expected a string"
end

local function int(min)
  return function(v)
    if type(v) == "number" and v == math.floor(v) and v >= (min or 0) then
      return v
    end
    return nil, ("expected an integer of at least %d"):format(min or 0)
  end
end

local function number(v)
  if type(v) == "number" then
    return v
  end
  return nil, "expected a number"
end

local function boolean(v)
  if type(v) == "boolean" then
    return v
  end
  return nil, "expected true or false"
end

---A color: "#rrggbb", "#rgb", a color name, or a highlight group name.
local function color(v)
  if type(v) ~= "string" or v == "" then
    return nil, 'expected a color ("#rrggbb", a name, or a highlight group)'
  end
  return v
end

---padding: N, [all], [vertical, horizontal], [top, horizontal, bottom], [t, r, b, l]
local function box4(v)
  if type(v) == "number" and v >= 0 and v == math.floor(v) then
    return { v, v, v, v }
  end
  if type(v) == "table" and #v >= 1 and #v <= 4 then
    local p = {}
    for i, x in ipairs(v) do
      if type(x) ~= "number" or x < 0 or x ~= math.floor(x) then
        return nil, "expected integers of at least 0"
      end
      p[i] = x
    end
    if #p == 1 then
      return { p[1], p[1], p[1], p[1] }
    elseif #p == 2 then
      return { p[1], p[2], p[1], p[2] }
    elseif #p == 3 then
      return { p[1], p[2], p[3], p[2] }
    end
    return p
  end
  return nil, "expected N or a list of 1 to 4 integers (top, right, bottom, left)"
end

---A border line style; true is single, false is none. "rich" (tables): a heavy header
---over a light body.
local BORDER = enum("single", "rounded", "heavy", "double", "dashed", "ascii", "rich", "none")
local function border(v)
  if v == true then
    return "single"
  elseif v == false then
    return "none"
  end
  return BORDER(v)
end

---A track list or a string of tracks (kept as written; layout parses it).
local function tracks(v)
  if type(v) == "number" or type(v) == "string" or type(v) == "table" then
    return v
  end
  return nil, "expected a number, a string or a list of tracks"
end

local function grid_line(v)
  if type(v) == "number" and v >= 1 and v == math.floor(v) then
    return v
  end
  if type(v) == "string" then
    local a = v:match("^(%d+)$")
    local span = v:match("^span%s+(%d+)$")
    local b, c = v:match("^(%d+)%s*/%s*span%s+(%d+)$")
    local ok = (a and tonumber(a) >= 1)
      or (span and tonumber(span) >= 1)
      or (b and tonumber(b) >= 1 and tonumber(c) >= 1)
    if ok then
      return v
    end
  end
  return nil, 'expected N, "span N" or "N / span M" (N, M at least 1)'
end

local function list_of_strings(v)
  if type(v) == "table" then
    for _, x in ipairs(v) do
      if type(x) ~= "string" then
        return nil, "expected a list of strings"
      end
    end
    return v
  end
  return nil, "expected a list of strings"
end

---@class dbdash.css.Property
---@field inherited boolean
---@field initial any
---@field parse fun(v: any): any, string?
---@field damage "repaint"|"relayout"|"rebuild"

---@type table<string, dbdash.css.Property>
M.list = {
  -- colors and glyphs
  ["color"] = { inherited = true, initial = nil, parse = color, damage = "repaint" },
  ["background-color"] = { inherited = false, initial = nil, parse = color, damage = "repaint" },
  ["font-weight"] = {
    inherited = true,
    initial = "normal",
    parse = enum("normal", "bold"),
    damage = "repaint",
  },
  ["font-style"] = {
    inherited = true,
    initial = "normal",
    parse = enum("normal", "italic"),
    damage = "repaint",
  },
  ["text-decoration"] = {
    inherited = false,
    initial = "none",
    parse = enum("none", "underline", "undercurl", "line-through"),
    damage = "repaint",
  },
  ["palette"] = { inherited = true, initial = "theme", parse = string_value, damage = "repaint" },
  -- display and generated content
  ["display"] = {
    inherited = false,
    initial = "block",
    parse = enum("block", "none"),
    damage = "rebuild",
  },
  ["content"] = { inherited = false, initial = nil, parse = string_value, damage = "relayout" },
  -- text
  ["text-align"] = {
    inherited = true,
    initial = "start",
    parse = enum("start", "left", "center", "right"),
    damage = "relayout",
  },
  ["vertical-align"] = {
    inherited = false,
    initial = "top",
    parse = enum("top", "middle", "bottom"),
    damage = "relayout",
  },
  ["white-space"] = {
    inherited = true,
    initial = "normal",
    parse = enum("normal", "nowrap"),
    damage = "relayout",
  },
  ["word-break"] = {
    inherited = true,
    initial = "normal",
    parse = enum("normal", "break-all"),
    damage = "relayout",
  },
  ["text-overflow"] = {
    inherited = false,
    initial = "ellipsis",
    parse = string_value,
    damage = "relayout",
  },
  ["line-clamp"] = { inherited = false, initial = nil, parse = int(1), damage = "relayout" },
  ["font-size"] = {
    inherited = true,
    initial = "normal",
    parse = enum("normal", "big"),
    damage = "relayout",
  },
  ["caption-side"] = {
    inherited = false,
    initial = "top",
    parse = enum("top", "bottom"),
    damage = "relayout",
  },
  -- boxes
  ["border"] = { inherited = false, initial = "none", parse = border, damage = "relayout" },
  ["border-color"] = { inherited = false, initial = nil, parse = color, damage = "repaint" },
  ["padding"] = { inherited = false, initial = { 0, 0, 0, 0 }, parse = box4, damage = "relayout" },
  ["width"] = { inherited = false, initial = nil, parse = int(1), damage = "relayout" },
  ["max-width"] = { inherited = false, initial = nil, parse = int(1), damage = "relayout" },
  ["height"] = { inherited = false, initial = nil, parse = int(1), damage = "relayout" },
  ["min-height"] = { inherited = false, initial = nil, parse = int(1), damage = "relayout" },
  -- grid container and items
  ["grid-template-columns"] = {
    inherited = false,
    initial = 1,
    parse = tracks,
    damage = "relayout",
  },
  ["grid-template-rows"] = { inherited = false, initial = nil, parse = tracks, damage = "relayout" },
  ["grid-auto-rows"] = { inherited = false, initial = "auto", parse = tracks, damage = "relayout" },
  ["grid-template-areas"] = {
    inherited = false,
    initial = nil,
    parse = list_of_strings,
    damage = "relayout",
  },
  ["column-gap"] = { inherited = false, initial = 2, parse = int(0), damage = "relayout" },
  ["row-gap"] = { inherited = false, initial = 1, parse = int(0), damage = "relayout" },
  ["grid-area"] = { inherited = false, initial = nil, parse = string_value, damage = "relayout" },
  ["grid-row"] = { inherited = false, initial = nil, parse = grid_line, damage = "relayout" },
  ["grid-column"] = { inherited = false, initial = nil, parse = grid_line, damage = "relayout" },
  ["justify-self"] = {
    inherited = false,
    initial = "stretch",
    parse = enum("start", "center", "end", "stretch"),
    damage = "relayout",
  },
  ["align-self"] = {
    inherited = false,
    initial = "start",
    parse = enum("start", "center", "end", "stretch"),
    damage = "relayout",
  },
  -- charts
  ["renderer"] = { inherited = true, initial = nil, parse = string_value, damage = "rebuild" },
  ["canvas"] = { inherited = true, initial = nil, parse = string_value, damage = "rebuild" },
  ["curve"] = {
    inherited = false,
    initial = "linear",
    parse = enum("linear", "step", "step-before", "step-after", "step-middle"),
    damage = "relayout",
  },
  ["fill"] = { inherited = false, initial = false, parse = boolean, damage = "relayout" },
  ["hole"] = { inherited = false, initial = 0, parse = number, damage = "relayout" },
  ["angle"] = {
    inherited = false,
    initial = 360,
    parse = function(v)
      if v == 180 or v == 360 then
        return v
      end
      return nil, "expected 180 or 360"
    end,
    damage = "relayout",
  },
  ["gap"] = { inherited = false, initial = nil, parse = int(0), damage = "relayout" },
  ["position"] = {
    inherited = false,
    initial = nil,
    parse = enum("right", "bottom", "end", "inside"),
    damage = "relayout",
  },
  ["color-scale"] = {
    inherited = false,
    initial = nil,
    parse = list_of_strings,
    damage = "repaint",
  },
  ["color-steps"] = {
    inherited = false,
    initial = nil,
    parse = function(v)
      if type(v) ~= "table" or #v == 0 then
        return nil, "expected a list of { value, color }"
      end
      for i, st in ipairs(v) do
        if
          type(st) ~= "table"
          or type(nn(st.value)) ~= "number"
          or type(nn(st.color)) ~= "string"
        then
          return nil, ("step %d: expected { value: number, color: string }"):format(i)
        end
      end
      return v
    end,
    damage = "repaint",
  },
}

---Parse a declared value of `name`.
---@return any value, string? err
function M.parse(name, v)
  local p = M.list[name]
  if not p then
    return nil, ("unknown property '%s'"):format(name)
  end
  v = nn(v)
  if v == nil then
    return nil, ("'%s' needs a value"):format(name)
  end
  return p.parse(v)
end

---The damage level (a number of M.DAMAGE) of a change of `name`.
function M.damage(name)
  local p = M.list[name]
  return p and M.DAMAGE[p.damage] or M.DAMAGE.rebuild
end

---Property names, sorted (for completion and documentation).
function M.names()
  local out = vim.tbl_keys(M.list)
  table.sort(out)
  return out
end

return M
