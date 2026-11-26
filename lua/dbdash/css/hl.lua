-- Computed style -> Neovim highlight group. A `color` that names an existing highlight
-- group with nothing else set is used as is (the UA sheet colors parts with the DbDash*
-- groups, so a colorscheme or the user can still restyle them). Anything else gets a
-- generated group combining the foreground, background and glyph attributes; generated
-- groups are re-created after :colorscheme from what they were made of.
local highlight = require("dbdash.render.highlight")

local M = {}

local made = {} ---@type table<string, table> name -> the parts it was made of

local function exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, create = false })
  return ok and next(hl) ~= nil
end

---A highlight group name: an existing group, or a name that is not a color (the DbDash*
---base groups may not be defined yet when a style is computed).
local function is_group(v)
  if type(v) ~= "string" or not v:match("^%u[%w_.@]*$") then
    return false
  end
  return exists(v) or highlight.parse(v) == nil
end

---Foreground (or, for a group, its foreground) of a color value.
local function fg_of(v)
  if is_group(v) then
    local h = vim.api.nvim_get_hl(0, { name = v, link = false })
    return h.fg, h
  end
  local attrs = highlight.parse(v)
  return attrs and attrs.fg or nil, attrs
end

local function build(parts)
  local attrs = {}
  if parts.color then
    local fg, src = fg_of(parts.color)
    attrs.fg = fg
    if is_group(parts.color) and src then
      -- keep the group's own attributes (bold titles stay bold)
      for _, k in ipairs({ "bold", "italic", "underline", "undercurl", "strikethrough", "reverse", "bg" }) do
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
      local a = highlight.parse(parts.bg)
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

---Highlight group for a computed style (nil when it sets nothing).
---@param c table<string, any>
---@return string?
function M.group(c)
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
  if parts.color and not (parts.bg or parts.bold or parts.italic or parts.decoration) and is_group(parts.color) then
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
