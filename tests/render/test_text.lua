-- text chart: the result as plain text.
local render = require("dbdash.render")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local function lines(rs, show, width, style)
  show.type = "text"
  return render.render(rs, show, { width = width or 40, style = style }).lines
end

local function rs(cols, rows, extra)
  local columns = {}
  for i, c in ipairs(cols) do
    columns[i] = { name = c[1], type = c[2] }
  end
  return resultset.new(columns, rows, extra)
end

T["one line per row; cells joined by spaces; strings as they are"] = function()
  local r = rs({ { "msg", "string" }, { "n", "integer" }, { "ok", "boolean" } }, {
    { "  start  ", 1, true },
    { "a\nb", 2.5, false },
    { vim.NIL, vim.NIL, vim.NIL },
  })
  eq(lines(r, { title = "Log" }), { "  start   1 true", "a", "b 2.5 false", "  " })
end

T["column_list, separator, cell.null content; tabs and CR"] = function()
  local r = rs({ { "a", "string" }, { "b", "string" } }, { { "x\ty", "1" }, { vim.NIL, "2\r\n3" } })
  eq(
    lines(
      r,
      { column_list = { "b", { column = "a" } }, separator = " | " },
      nil,
      { ["cell.null"] = { content = "-" } }
    ),
    {
      "1 | x   y", -- the tab stops at column 8 of the line
      "2",
      "3 | -",
    }
  )
  local o = render.render(r, { type = "text", column_list = { "nope" } }, { width = 40 })
  eq(o.lines[1], "column_list: no column 'nope' in the result")
end

T["long lines wrap by display width, or are cut with white-space: nowrap"] = function()
  local r = rs({ { "s", "string" } }, { { ("abcdefghij"):rep(3) }, { ("中"):rep(12) } })
  eq(lines(r, {}, 20), { "abcdefghijabcdefghij", "abcdefghij", ("中"):rep(10), ("中"):rep(2) })
  eq(
    lines(r, {}, 20, { line = { ["white-space"] = "nowrap" } }),
    { "abcdefghijabcdefghij", ("中"):rep(10) }
  )
end

T["no rows; truncated results"] = function()
  local o = render.render(rs({ { "s", "string" } }, {}), { type = "text" }, { width = 40 })
  eq({ o.lines, o.hl[1].group }, { { "(no rows)" }, "DbDashMuted" })
  eq(lines(rs({ { "s", "string" } }, { { "a" } }, { truncated = true }), {}), {
    "a",
    "… showing the first 1 rows (query.max_rows)",
  })
end

return T
