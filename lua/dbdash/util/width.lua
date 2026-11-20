-- Display-width helpers built on strdisplaywidth, aware of wide (CJK) characters.
local M = {}

local cache = {}

-- Matches one UTF-8 encoded character (lenient: also accepts stray bytes).
local CHAR = "[%z\1-\127\192-\247][\128-\191]*"

---Display width of a string in screen cells.
---@param s string
---@return integer
function M.width(s)
  if not s:find("[\128-\255]") then
    return #s
  end
  return vim.fn.strdisplaywidth(s)
end

---Display width of a single character, cached.
---@param ch string
---@return integer
local function char_width(ch)
  local w = cache[ch]
  if not w then
    w = #ch == 1 and 1 or vim.fn.strdisplaywidth(ch)
    cache[ch] = w
  end
  return w
end

---Iterate over the UTF-8 characters of a string.
---@param s string
---@return fun(): string?
function M.chars(s)
  return s:gmatch(CHAR)
end

---Truncate `s` so it fits in `max` cells, appending `ellipsis` when shortened.
---@param s string
---@param max integer
---@param ellipsis string? defaults to "…"; pass "" for a hard cut
---@return string
function M.truncate(s, max, ellipsis)
  if max <= 0 then
    return ""
  end
  if M.width(s) <= max then
    return s
  end
  ellipsis = ellipsis or "…"
  local ew = M.width(ellipsis)
  if ew > max then
    ellipsis, ew = "", 0
  end
  local budget = max - ew
  local out, used = {}, 0
  for ch in M.chars(s) do
    local w = char_width(ch)
    if used + w > budget then
      break
    end
    out[#out + 1] = ch
    used = used + w
  end
  return table.concat(out) .. ellipsis
end

---Pad `s` with spaces to exactly `w` cells (truncating first if it is wider).
---@param s string
---@param w integer
---@param align? "left"|"right"|"center"
---@return string
function M.pad(s, w, align)
  s = M.truncate(s, w)
  local gap = w - M.width(s)
  if gap <= 0 then
    return s
  end
  if align == "right" then
    return string.rep(" ", gap) .. s
  elseif align == "center" then
    local left = math.floor(gap / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", gap - left)
  end
  return s .. string.rep(" ", gap)
end

return M
