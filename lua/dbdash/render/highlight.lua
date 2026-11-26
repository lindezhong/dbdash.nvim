-- Color specs -> highlight groups (design §4.3).
--
-- Accepted specs: "#3498db", color names ("blue"), rich-style styles ("bold blue",
-- "italic red on black", "bold"), or an existing highlight group ("DiagnosticOk").
-- Generated groups are cached and re-created after :colorscheme.
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
  DbDashArgLocal = { link = "Special" },
  DbDashDescIcon = { link = "Comment" }, -- ⓘ: a description to read with K -- a panel's local argument on its args_show line
  -- Stat chart: the value, and its change since the previous refresh.
  DbDashStatValue = { link = "Number" },
  DbDashUp = { link = "DiagnosticOk" },
  DbDashDown = { link = "DiagnosticError" },
  -- Sidebar: directories (name and arrow), running and idle dashboards.
  DbDashSidebarDir = { link = "Directory" },
  DbDashTrustFile = { link = "Title" }, -- file separators in the trust View float
  -- Sidebar cursor line: the window's CursorLine (empty) and the underline of the cursor
  -- line's name, which leaves the ●/◐/○ marker in its own color.
  DbDashSidebarCursorLine = {},
  DbDashSidebarCursor = { underline = true, cterm = { underline = true } },
  DbDashSidebarRunning = { link = "DiagnosticOk" },
  DbDashSidebarPaused = { link = "DiagnosticWarn" },
  DbDashSidebarIdle = { link = "Normal" },
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
  require("dbdash.css.hl").refresh() -- groups made from computed styles
end

return M
