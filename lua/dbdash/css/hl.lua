-- Highlight groups of dashboards: the DbDash* base groups (defined with default = true, so
-- a colorscheme or the user can restyle them), color specs and the groups of computed
-- styles; generated groups are re-created after :colorscheme.
--
-- Color specs: "#3498db", color names ("blue"), rich-style styles ("bold blue", "italic
-- red on black", "bold"), or an existing highlight group ("DiagnosticOk").
--
-- Computed style -> group: a `color` that names an existing highlight group with nothing
-- else set is used as is (the UA sheet colors parts with the DbDash* groups). Anything else
-- gets a generated group combining the foreground, background and glyph attributes.
local M = {}

local ATTRS = {
  bold = "bold",
  italic = "italic",
  underline = "underline",
  undercurl = "undercurl",
  strikethrough = "strikethrough",
  reverse = "reverse",
  dim = "dim",
}

-- Base groups, linked to standard groups so they follow the colorscheme.
M.BASE = {
  DbDashTitle = { link = "Title" },
  DbDashBorder = { link = "FloatBorder" },
  DbDashHeader = { link = "Statement" },
  DbDashNull = { link = "Comment" },
  DbDashMuted = { link = "Comment" },
  DbDashNumber = { link = "Number" },
  DbDashAxis = { link = "Comment" },
  DbDashLabel = { link = "Normal" },
  DbDashLegend = { link = "DbDashLabel" }, -- legend labels (style.legend_style)
  DbDashText = { link = "Normal" }, -- text chart lines (style.color)
  DbDashGrid = { link = "NonText" }, -- grid lines (axes.*.grid)
  DbDashMark = { link = "WarningMsg" }, -- reference lines and points (mark_lines, mark_points)
  DbDashError = { link = "DiagnosticError" },
  DbDashWarn = { link = "DiagnosticWarn" },
  DbDashCountdown = { link = "Comment" },
  DbDashArgName = { link = "Identifier" },
  DbDashArgValue = { link = "String" },
  DbDashArgLocal = { link = "Special" }, -- a panel's local argument on its args_show line
  DbDashDescIcon = { link = "Comment" }, -- ⓘ: a description to read with K
  -- Stat chart: the value, and its change since the previous refresh.
  DbDashStatValue = { link = "Number" },
  DbDashUp = { link = "DiagnosticOk" },
  DbDashDown = { link = "DiagnosticError" },
  -- Sidebar: directories (name and arrow); the marks of the configs below.
  DbDashSidebarDir = { link = "Directory" },
  DbDashTrustFile = { link = "Title" }, -- file separators in the trust View float
  -- Sidebar cursor line: the window's CursorLine (empty) and the underline of the cursor
  -- line's name, which leaves the ●/◐/○ marker in its own color.
  DbDashSidebarCursorLine = {},
  DbDashSidebarCursor = { underline = true, cterm = { underline = true } },
  -- the marks: every panel fetches, some do, none does (paused), not running
  DbDashSidebarFetching = { link = "DiagnosticOk" },
  DbDashSidebarPartly = { link = "DiagnosticWarn" },
  DbDashSidebarPaused = { link = "DiagnosticInfo" },
  DbDashSidebarStopped = { link = "Comment" },
  -- Series colors, taken from common syntax groups so they follow the colorscheme.
  DbDashSeries1 = { link = "Function" },
  DbDashSeries2 = { link = "String" },
  DbDashSeries3 = { link = "Constant" },
  DbDashSeries4 = { link = "Statement" },
  DbDashSeries5 = { link = "Type" },
  DbDashSeries6 = { link = "Special" },
  DbDashSeries7 = { link = "Identifier" },
  DbDashSeries8 = { link = "PreProc" },
}

local defined = {} ---@type table<string, table> group -> attributes, for re-creation

---Parse a spec into nvim_set_hl attributes; nil when it names an existing group.
---@param spec string
---@return table? attrs, string? err
function M.parse(spec)
  local attrs = {}
  local words = vim.split(vim.trim(spec), "%s+")
  local i = 1
  local target = "fg"
  while i <= #words do
    local w = words[i]
    local lw = w:lower()
    if ATTRS[lw] then
      if lw ~= "dim" then
        attrs[ATTRS[lw]] = true
      end
    elseif lw == "on" then
      target = "bg"
    elseif lw == "not" then
      i = i + 1 -- "not bold" etc.: ignore the attribute
    elseif w:match("^#%x%x%x%x%x%x$") then
      attrs[target] = w
    elseif w:match("^#%x%x%x$") then
      attrs[target] = "#" .. w:sub(2, 2):rep(2) .. w:sub(3, 3):rep(2) .. w:sub(4, 4):rep(2)
    elseif vim.api.nvim_get_color_by_name((lw:gsub("_", ""))) ~= -1 then
      attrs[target] = (lw:gsub("_", ""))
    elseif lw:match("^bright_") and vim.api.nvim_get_color_by_name("light" .. lw:sub(8)) ~= -1 then
      attrs[target] = "light" .. lw:sub(8)
    else
      return nil, ("unknown color or style %q"):format(w)
    end
    i = i + 1
  end
  return attrs
end

---Group name for a spec (pure; does not define it).
---@param spec string
---@return string
function M.group_name(spec)
  return "DbDashC_" .. vim.trim(spec):lower():gsub("[^%w]+", "_")
end

local function exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, create = false })
  return ok and next(hl) ~= nil
end

---Highlight group for a color spec, defining it on first use.
---Unknown specs fall back to `fallback` (or Normal).
---@param spec string?
---@param fallback string?
---@return string
function M.color(spec, fallback)
  if spec == nil or spec == vim.NIL or spec == "" then
    return fallback or "Normal"
  end
  spec = tostring(spec)
  if spec:match("^%u[%w_.@]*$") and exists(spec) then
    return spec
  end
  local name = M.group_name(spec)
  if defined[name] then
    return name
  end
  local attrs = M.parse(spec)
  if not attrs then
    return fallback or "Normal"
  end
  defined[name] = attrs
  vim.api.nvim_set_hl(0, name, attrs)
  return name
end

---Define base groups (default=true so user overrides win) and re-create generated ones.
function M.setup()
  for name, attrs in pairs(M.BASE) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", attrs, { default = true }))
  end
  for name, attrs in pairs(defined) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
  M.refresh() -- groups made from computed styles
end

-- Groups of computed styles ---------------------------------------------------------------

local made = {} ---@type table<string, table> name -> the parts it was made of

---A highlight group name: an existing group, or a name that is not a color (the DbDash*
---base groups may not be defined yet when a style is computed).
local function is_group(v)
  if type(v) ~= "string" or not v:match("^%u[%w_.@]*$") then
    return false
  end
  return exists(v) or M.parse(v) == nil
end

---Foreground (or, for a group, its foreground) of a color value.
local function fg_of(v)
  if is_group(v) then
    local h = vim.api.nvim_get_hl(0, { name = v, link = false })
    return h.fg, h
  end
  local attrs = M.parse(v)
  return attrs and attrs.fg or nil, attrs
end

local function build(parts)
  local attrs = {}
  if parts.color then
    local fg, src = fg_of(parts.color)
    attrs.fg = fg
    if is_group(parts.color) and src then
      -- keep the group's own attributes (bold titles stay bold)
      for _, k in ipairs({
        "bold",
        "italic",
        "underline",
        "undercurl",
        "strikethrough",
        "reverse",
        "bg",
      }) do
        if src[k] ~= nil then
          attrs[k] = src[k]
        end
      end
    end
  end
  if parts.bg then
    if is_group(parts.bg) then
      local h = vim.api.nvim_get_hl(0, { name = parts.bg, link = false })
      attrs.bg = h.bg or h.fg
    else
      local a = M.parse(parts.bg)
      attrs.bg = a and (a.bg or a.fg) or nil
    end
  end
  if parts.bold then
    attrs.bold = true
  end
  if parts.italic then
    attrs.italic = true
  end
  if parts.decoration == "underline" then
    attrs.underline = true
  elseif parts.decoration == "undercurl" then
    attrs.undercurl = true
  elseif parts.decoration == "line-through" then
    attrs.strikethrough = true
  end
  return attrs
end

-- Groups of computed tables: shared styles (css/style.lua) resolve their group once.
local memo = setmetatable({}, { __mode = "k" })
local NONE = {}

---Highlight group for a computed style (nil when it sets nothing).
---@param c table<string, any>
---@return string?
function M.group(c)
  local m = memo[c]
  if m ~= nil then
    return m ~= NONE and m or nil
  end
  local g = M.make(c)
  memo[c] = g or NONE
  return g
end

---The group of a computed style, without the memo (M.group caches it per table).
function M.make(c)
  local parts = {
    color = c["color"],
    bg = c["background-color"],
    bold = c["font-weight"] == "bold" or nil,
    italic = c["font-style"] == "italic" or nil,
    decoration = c["text-decoration"] ~= "none" and c["text-decoration"] or nil,
  }
  if not (parts.color or parts.bg or parts.bold or parts.italic or parts.decoration) then
    return nil
  end
  if
    parts.color
    and not (parts.bg or parts.bold or parts.italic or parts.decoration)
    and is_group(parts.color)
  then
    return parts.color
  end
  local key = table.concat({
    tostring(parts.color or ""),
    tostring(parts.bg or ""),
    parts.bold and "b" or "",
    parts.italic and "i" or "",
    tostring(parts.decoration or ""),
  }, "|")
  local name = "DbDashCss_" .. key:gsub("[^%w]", "_")
  if not made[name] then
    made[name] = parts
    vim.api.nvim_set_hl(0, name, build(parts))
  end
  return name
end

---Re-create the generated groups (after :colorscheme).
function M.refresh()
  for name, parts in pairs(made) do
    vim.api.nvim_set_hl(0, name, build(parts))
  end
end

return M
