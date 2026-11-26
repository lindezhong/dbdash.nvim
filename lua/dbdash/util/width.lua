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

---Cut `s` into pieces of at most `width` cells, character by character.
---@param s string
---@param width integer
---@return string[]
local function hard_wrap(s, width)
  local pieces, cur, used = {}, {}, 0
  for ch in M.chars(s) do
    local w = char_width(ch)
    if used + w > width and used > 0 then
      pieces[#pieces + 1] = table.concat(cur)
      cur, used = {}, 0
    end
    cur[#cur + 1] = ch
    used = used + w
  end
  pieces[#pieces + 1] = table.concat(cur)
  return pieces
end

---Wrap one line (no newlines) into lines of at most `width` cells, like CSS white-space:
---normal: "word" breaks at spaces (a word wider than the line is cut, like
---overflow-wrap: anywhere) and drops the spaces at the breaks; "char" breaks anywhere.
---@param s string
---@param width integer
---@param mode? "word"|"char" default "word"
---@return string[]
function M.wrap(s, width, mode)
  width = math.max(width, 1)
  if M.width(s) <= width then
    return { s }
  end
  if mode == "char" then
    return hard_wrap(s, width)
  end
  local lines, cur, used = {}, "", 0
  local function flush()
    lines[#lines + 1] = (cur:gsub("%s+$", ""))
    cur, used = "", 0
  end
  -- Tokens: a run of non-spaces with the spaces after it.
  for word, spaces in s:gmatch("([^ ]*)( *)") do
    if word == "" and spaces == "" then
      break
    end
    local ww = M.width(word)
    if used > 0 and used + ww > width then
      flush()
    end
    if ww > width then
      local pieces = hard_wrap(word, width)
      for i = 1, #pieces - 1 do
        cur = pieces[i]
        flush()
      end
      cur, used = pieces[#pieces], M.width(pieces[#pieces])
    else
      cur, used = cur .. word, used + ww
    end
    if used > 0 then
      -- Spaces past the edge are dropped at the break.
      local room = width - used
      local sp = math.min(#spaces, math.max(room, 0))
      cur, used = cur .. spaces:sub(1, sp), used + sp
      if #spaces > room then
        flush()
      end
    end
  end
  if cur ~= "" or #lines == 0 then
    flush()
  end
  return lines
end

---Keep at most `max` lines; when some are dropped, the last kept line ends with
---`ellipsis` (default "…") within `width` cells, like CSS line-clamp.
---@param lines string[]
---@param max integer?
---@param width integer
---@param ellipsis string?
---@return string[]
function M.clamp(lines, max, width, ellipsis)
  if not max or #lines <= max then
    return lines
  end
  ellipsis = ellipsis or "…"
  local out = { unpack(lines, 1, max) }
  local last = out[max]
  local ew = M.width(ellipsis)
  if M.width(last) + ew > width then
    last = M.truncate(last, math.max(width - ew, 0), "") .. ellipsis
  else
    last = last .. ellipsis
  end
  out[max] = last
  return out
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
