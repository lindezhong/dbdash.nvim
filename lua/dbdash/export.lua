-- Export a result set as text: csv, tsv, json or markdown (:DbDashExport).
local M = {}

M.FORMATS = { "csv", "tsv", "json", "markdown" }

local NULL = vim.NIL

---Text of one value; nil for NULL. Bytes become \x hex, JSON values their JSON text.
---@param v any
---@param col dbdash.db.Column
---@return string?
local function text(v, col)
  if v == nil or v == NULL then
    return nil
  end
  local t = type(v)
  if t == "string" then
    if col.type == "bytes" then
      return "\\x" .. require("dbdash.db.resultset").hex(v)
    end
    return v
  elseif t == "number" then
    return require("dbdash.template.runtime").numstr(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "cdata" then
    return (tostring(v):gsub("U?LL$", "")) -- 64-bit integers
  elseif t == "table" then
    local ok, j = pcall(vim.json.encode, v)
    return ok and j or tostring(v)
  end
  return tostring(v)
end

local function csv_field(s)
  if s:find('[,"\r\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function tsv_field(s)
  return (s:gsub("[\\\t\r\n]", { ["\\"] = "\\\\", ["\t"] = "\\t", ["\r"] = "\\r", ["\n"] = "\\n" }))
end

local function md_field(s)
  return (s:gsub("|", "\\|"):gsub("\r?\n", "<br>"))
end

---JSON text of one value (numbers stay numbers, NULL is null).
local function json_value(v, col)
  if v == nil or v == NULL then
    return "null"
  end
  local t = type(v)
  if t == "number" or t == "boolean" then
    local ok, j = pcall(vim.json.encode, v)
    if ok then
      return j
    end
  elseif t == "cdata" then
    return text(v, col)
  elseif t == "table" then
    local ok, j = pcall(vim.json.encode, v)
    if ok then
      return j
    end
  end
  return vim.json.encode(text(v, col))
end

---Column names made unique for JSON keys ("id", "id_2", ...).
local function unique_names(columns)
  local seen, out = {}, {}
  for i, c in ipairs(columns) do
    local name = c.name
    if seen[name] then
      local n = 2
      while seen[name .. "_" .. n] do
        n = n + 1
      end
      name = name .. "_" .. n
    end
    seen[name] = true
    out[i] = name
  end
  return out
end

---Format a result set.
---@param rs dbdash.db.ResultSet
---@param fmt "csv"|"tsv"|"json"|"markdown"
---@return string
function M.format(rs, fmt)
  local cols = rs.columns
  local lines = {}
  if fmt == "csv" or fmt == "tsv" then
    local field = fmt == "csv" and csv_field or tsv_field
    local sep = fmt == "csv" and "," or "\t"
    local head = {}
    for i, c in ipairs(cols) do
      head[i] = field(c.name)
    end
    lines[1] = table.concat(head, sep)
    for _, row in ipairs(rs.rows) do
      local cells = {}
      for i, c in ipairs(cols) do
        local s = text(row[i], c)
        cells[i] = s and field(s) or ""
      end
      lines[#lines + 1] = table.concat(cells, sep)
    end
  elseif fmt == "json" then
    local names = unique_names(cols)
    lines[1] = "["
    for r, row in ipairs(rs.rows) do
      local fields = {}
      for i, c in ipairs(cols) do
        fields[i] = vim.json.encode(names[i]) .. ": " .. json_value(row[i], c)
      end
      lines[#lines + 1] = "  {" .. table.concat(fields, ", ") .. "}" .. (r < #rs.rows and "," or "")
    end
    lines[#lines + 1] = "]"
  elseif fmt == "markdown" then
    local head, rule = {}, {}
    for i, c in ipairs(cols) do
      head[i] = md_field(c.name)
      local numeric = c.type == "integer" or c.type == "number" or c.type == "decimal"
      rule[i] = numeric and "---:" or "---"
    end
    lines[1] = "| " .. table.concat(head, " | ") .. " |"
    lines[2] = "| " .. table.concat(rule, " | ") .. " |"
    for _, row in ipairs(rs.rows) do
      local cells = {}
      for i, c in ipairs(cols) do
        cells[i] = md_field(text(row[i], c) or "")
      end
      lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
  else
    error(("unknown export format %q (use %s)"):format(tostring(fmt), table.concat(M.FORMATS, ", ")), 0)
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
