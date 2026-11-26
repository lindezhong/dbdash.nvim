-- Generate doc/dbdash-schema.txt, the help file with example/dbdash.schema.yaml, from that
-- schema: `make doc` (nvim -l scripts/schema_doc.lua). tests/test_doc.lua checks that the
-- help file is up to date.
--
-- The schema is shown as YAML code blocks with a tag before every field (:helptags does
-- not read tags inside code blocks):
--   dbdash-schema-<field>            top-level fields (dbdash-schema-layout.columns)
--   dbdash-schema-def-<name>         an entry of `definitions` (dbdash-schema-def-show)
--   dbdash-schema-<name>.<field>     a field of a definition (dbdash-schema-show.interval,
--                                    dbdash-schema-database.options.lib_path)
local M = {}

M.SCHEMA = "example/dbdash.schema.yaml"
M.HELP = "doc/dbdash-schema.txt"

local WIDTH = 78

---Help tags of the schema's lines: { [line number] = tag }.
---@param lines string[]
---@return table<integer, string>
function M.tags(lines)
  local tags, used = {}, {}
  local stack = {} -- { indent, key, field } from the root to the current line's parent
  for i, line in ipairs(lines) do
    local indent, dash, key = line:match("^(%s*)(%-?%s*)([%w_$][%w_$-]*):")
    if key and not line:match("^%s*#") then
      local depth = #indent + #dash -- a list item's keys are one level in
      while #stack > 0 and stack[#stack].indent >= depth do
        table.remove(stack)
      end
      local parent = stack[#stack]
      local root = stack[1]
      local entry = { indent = depth, key = key }
      if root and root.key == "definitions" and #stack == 1 then
        entry.field = { key }
        tags[i] = "dbdash-schema-def-" .. key
      elseif parent and parent.key == "properties" and root and (root.key == "properties" or root.key == "definitions") then
        -- A field: the nearest field above it (or the definition) gives its path.
        local base
        for j = #stack, 1, -1 do
          if stack[j].field then
            base = stack[j].field
            break
          end
        end
        entry.field = vim.list_extend(vim.deepcopy(base or {}), { key })
        tags[i] = "dbdash-schema-" .. table.concat(entry.field, ".")
      end
      if tags[i] then
        if used[tags[i]] then
          tags[i] = nil -- keep the first one: tags must be unique
        else
          used[tags[i]] = true
        end
      end
      stack[#stack + 1] = entry
    end
  end
  return tags
end

---The help file for the schema text.
---@param text string
---@return string
function M.render(text)
  text = text:gsub("\r\n", "\n") -- a Windows checkout may have CRLF line ends
  local lines = vim.split(text:gsub("\n$", ""), "\n", { plain = true })
  local tags = M.tags(lines)
  local out = {
    "*dbdash-schema.txt*  JSON Schema of dbdash.nvim config files",
    "",
    "Generated from `example/dbdash.schema.yaml` by `make doc`; edit that file, not",
    "this one. Editors with yaml-language-server use it to validate and complete",
    "configs (|dbdash-examples|). Every field has a tag:",
    "",
    "  dbdash-schema-<field>          top-level fields, e.g. |dbdash-schema-panels|",
    "  dbdash-schema-def-<name>       a definition, e.g. |dbdash-schema-def-show|",
    "  dbdash-schema-<name>.<field>   its fields, e.g. |dbdash-schema-show.interval|",
    "",
    "==============================================================================",
    "                                                               *dbdash-schema*",
    "",
  }
  local open = false
  for i, line in ipairs(lines) do
    if tags[i] then
      if open then
        out[#out + 1] = "<"
      end
      local tag = ("*%s* >yaml"):format(tags[i])
      out[#out + 1] = string.rep(" ", math.max(1, WIDTH - #tag)) .. tag
      open = true
    elseif not open then
      out[#out + 1] = ">yaml"
      open = true
    end
    out[#out + 1] = line == "" and "" or ("  " .. line)
  end
  if open then
    out[#out + 1] = "<"
  end
  out[#out + 1] = ""
  out[#out + 1] = " vim:tw=78:ts=8:ft=help:norl:"
  return table.concat(out, "\n") .. "\n"
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
M.read = read

-- nvim -l scripts/schema_doc.lua: write the help file.
if _G.arg and _G.arg[0] and _G.arg[0]:match("schema_doc%.lua$") then
  local f = assert(io.open(M.HELP, "wb"))
  f:write(M.render(read(M.SCHEMA)))
  f:close()
  print("wrote " .. M.HELP)
end

return M
