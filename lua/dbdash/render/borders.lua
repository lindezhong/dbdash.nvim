-- Border line styles (CSS border-style): the box-drawing characters of each style.
--   tl tr bl br   corners      h v      lines
--   lt rt         ├ ┤          tt bt    ┬ ┴      x  ┼
local M = {}

M.STYLES = {
  single = {
    tl = "┌",
    tr = "┐",
    bl = "└",
    br = "┘",
    h = "─",
    v = "│",
    lt = "├",
    rt = "┤",
    tt = "┬",
    bt = "┴",
    x = "┼",
  },
  rounded = {
    tl = "╭",
    tr = "╮",
    bl = "╰",
    br = "╯",
    h = "─",
    v = "│",
    lt = "├",
    rt = "┤",
    tt = "┬",
    bt = "┴",
    x = "┼",
  },
  heavy = {
    tl = "┏",
    tr = "┓",
    bl = "┗",
    br = "┛",
    h = "━",
    v = "┃",
    lt = "┣",
    rt = "┫",
    tt = "┳",
    bt = "┻",
    x = "╋",
  },
  double = {
    tl = "╔",
    tr = "╗",
    bl = "╚",
    br = "╝",
    h = "═",
    v = "║",
    lt = "╠",
    rt = "╣",
    tt = "╦",
    bt = "╩",
    x = "╬",
  },
  dashed = {
    tl = "┌",
    tr = "┐",
    bl = "└",
    br = "┘",
    h = "╌",
    v = "╎",
    lt = "├",
    rt = "┤",
    tt = "┬",
    bt = "┴",
    x = "┼",
  },
  ascii = {
    tl = "+",
    tr = "+",
    bl = "+",
    br = "+",
    h = "-",
    v = "|",
    lt = "+",
    rt = "+",
    tt = "+",
    bt = "+",
    x = "+",
  },
}

M.NAMES = { "single", "rounded", "heavy", "double", "dashed", "ascii", "none" }

---The characters for a style.border value: nil / true -> `default`, false / "none" -> nil.
---@param v any
---@param default string
---@return table? chars, string? name
function M.get(v, default)
  if v == vim.NIL or v == nil or v == true then
    v = default
  end
  if v == false or v == "none" then
    return nil
  end
  return M.STYLES[v] or M.STYLES[default], M.STYLES[v] and v or default
end

return M
