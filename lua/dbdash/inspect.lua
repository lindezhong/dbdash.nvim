-- :DbDashInspect, the dashboard's DevTools inspector (after Servo's devtools actors, which
-- read layout through query APIs): the element under the cursor, the rules that match it
-- with their origin and specificity, its computed style, its box and highlight group, and
-- its parts. The element's box is highlighted in the dashboard until the cursor moves.
local css = require("dbdash.css")
local style = require("dbdash.css.style")
local properties = require("dbdash.css.properties")

local M = {}

M.ns = vim.api.nvim_create_namespace("dbdash_inspect")

local function value_text(v)
  if type(v) == "table" then
    return vim.inspect(v, { newline = " ", indent = "" })
  end
  return tostring(v)
end

---The path from the root: "dashboard > panel#a.table > chart.table".
function M.path(node)
  local parts = {}
  for _, n in ipairs(node:ancestors()) do
    table.insert(parts, 1, n:describe())
  end
  return table.concat(parts, " > ")
end

---The inspector's text for an element.
---@param node dbdash.dom.Node
---@param box { row_s: integer, row_e: integer, x: integer, width: integer }?
---@return string[] lines
function M.report(node, box)
  local doc = node.document
  local computed = style.get(node)
  local lines = { M.path(node), "" }
  if box then
    lines[#lines + 1] = ("box        lines %d-%d, columns %d-%d"):format(box.row_s + 1, box.row_e + 1, box.x, box.x + box.width - 1)
  end
  lines[#lines + 1] = "highlight  " .. (css.hl_of(node) or "(none)")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Matched rules (the last wins):"
  local matched = style.matching(doc, node)
  if #matched == 0 then
    lines[#lines + 1] = "  (none)"
  end
  for _, m in ipairs(matched) do
    local sp = m.rule.selector.specificity
    local decls = {}
    local keys = vim.tbl_keys(m.rule.decls)
    table.sort(keys)
    for _, k in ipairs(keys) do
      decls[#decls + 1] = ("%s: %s"):format(k, value_text(m.rule.decls[k]))
    end
    lines[#lines + 1] = ("  %-8s %s  (%d,%d,%d)"):format(m.origin, m.rule.selector.text, sp[1], sp[2], sp[3])
    lines[#lines + 1] = "           { " .. table.concat(decls, "; ") .. " }"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Computed (other than the initial values):"
  local any = false
  for _, name in ipairs(properties.names()) do
    local v = computed[name]
    if v ~= nil and not vim.deep_equal(v, properties.list[name].initial) then
      lines[#lines + 1] = ("  %-22s %s"):format(name, value_text(v))
      any = true
    end
  end
  if not any then
    lines[#lines + 1] = "  (all initial)"
  end
  local kids, seen = {}, {}
  for _, c in ipairs(node.children) do
    if not (c.attrs and c.attrs.placeholder) then
      local d = c:describe()
      if not seen[d] then
        seen[d] = true
        kids[#kids + 1] = d
      end
    end
  end
  if #kids > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Children: " .. table.concat(kids, ", ")
  end
  return lines
end

---The recorded box of a node (the hit-test regions painting recorded).
---The byte index of display column `col` in `text` (the end when past it).
local function byte_at(text, col)
  local w, i = 0, 0
  while i < #text and w < col do
    local ch = vim.fn.strcharpart(text:sub(i + 1), 0, 1)
    w = w + vim.fn.strdisplaywidth(ch)
    i = i + #ch
  end
  return i
end

local function box_of(d, node)
  for _, h in ipairs(d.hits or {}) do
    if h.node == node then
      return h
    end
  end
end

---Inspect the element under the cursor of a dashboard, or the nearest element named
---`tag` from there (a part of the chart: `:DbDashInspect series`; its panel's title:
---`:DbDashInspect panel-title`).
function M.open(d, tag)
  local events = require("dbdash.events")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local dcol = vim.fn.strdisplaywidth(line:sub(1, cursor[2]))
  local node = events.hit_test(d, cursor[1], dcol)
  if not node then
    return vim.notify("dbdash: nothing to inspect", vim.log.levels.WARN)
  end
  local box_node = node
  if tag then
    -- in the element under the cursor, else in its nearest ancestor that has one (the
    -- panel's title from its chart)
    local found
    for _, a in ipairs(node:ancestors()) do
      found = a:find(function(n)
        return n.tag == tag and not (n.attrs and n.attrs.placeholder)
      end)
      if found then
        break
      end
    end
    if not found then
      return vim.notify(("dbdash: no %s in %s"):format(tag, node:describe()), vim.log.levels.WARN)
    end
    node = found
  end
  local box = box_of(d, box_node)
  -- highlight the box in the dashboard until the cursor moves
  local buf = d.buf
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if box then
    for r = box.row_s, box.row_e do
      local text = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
      local s, e = byte_at(text, box.x), byte_at(text, box.x + box.width)
      if e > s then
        vim.api.nvim_buf_set_extmark(buf, M.ns, r, s, { end_col = e, hl_group = "Visual", priority = 300 })
      end
    end
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      once = true,
      callback = function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
        end
      end,
    })
  end
  return require("dbdash.view.popup").open(M.report(node, box), { title = "DbDash inspect: " .. node:describe() })
end

---Tags under the element at the cursor, for completion.
function M.tags(d)
  local out, seen = {}, {}
  if d and d.doc then
    d.doc.root:walk(function(n)
      if not seen[n.tag] then
        seen[n.tag] = true
        out[#out + 1] = n.tag
      end
    end)
  end
  table.sort(out)
  return out
end

return M
