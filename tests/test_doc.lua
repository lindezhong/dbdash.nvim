-- doc/dbdash.txt must stay complete: every command, template filter, test, global
-- and setup option is documented, help tags build, and lines fit in 78 columns.
-- doc/dbdash-schema.txt must match example/dbdash.schema.yaml, and doc/tags the help files
-- (make doc).
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local DOC = table.concat(vim.fn.readfile("doc/dbdash.txt"), "\n")

local function missing(names, fmt)
  local out = {}
  for _, n in ipairs(names) do
    if not DOC:find(fmt:format(n), 1, true) then
      out[#out + 1] = n
    end
  end
  table.sort(out)
  return out
end

T["every user command has a help tag"] = function()
  vim.cmd("runtime plugin/dbdash.lua")
  local names = {}
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^DbDash") or name == "Mksession" then
      names[#names + 1] = name
    end
  end
  eq(#names > 10, true)
  eq(missing(names, "*:%s*"), {})
end

T["every template filter, test and global is documented"] = function()
  require("dbdash.template")
  local R = require("dbdash.template.runtime")
  local names = {}
  for _, tbl in ipairs({ R.filters, R.tests, R.globals }) do
    for k in pairs(tbl) do
      names[#names + 1] = k
    end
  end
  eq(missing(names, "%s"), {})
  local methods = {}
  for _, fns in pairs(require("dbdash.template.methods").by_type) do
    for k in pairs(fns) do
      methods[#methods + 1] = k
    end
  end
  eq(missing(methods, "%s()"), {})
end

T["every setup option is documented"] = function()
  local names = {}
  for k, v in pairs(require("dbdash.options").DEFAULTS) do
    names[#names + 1] = k
    if type(v) == "table" and not vim.islist(v) then
      for sub in pairs(v) do
        names[#names + 1] = sub
      end
    end
  end
  table.insert(names, "height") -- nil by default, so not a key of DEFAULTS.defaults
  eq(missing(names, " %s = "), {})
end

T["every CSS property and element is documented and in the schema"] = function()
  local props = require("dbdash.css.properties").names()
  local schema = table.concat(vim.fn.readfile("example/dbdash.schema.yaml"), "\n")
  local not_in_schema = {}
  for _, name in ipairs(props) do
    if not schema:find("\n        " .. name .. ":", 1, true) then
      not_in_schema[#not_in_schema + 1] = name
    end
  end
  eq(not_in_schema, {})
  -- the properties section of the help names each one
  local section = DOC:match("%*dbdash%-css%-properties%*(.-)%*dbdash%-rendering%*")
  local not_in_help = {}
  for _, name in ipairs(props) do
    if not section:find(name, 1, true) then
      not_in_help[#not_in_help + 1] = name
    end
  end
  eq(not_in_help, {})
  -- every element the default sheet styles is in the element tree of the help
  local elements = DOC:match("%*dbdash%-css%-elements%*(.-)%*dbdash%-css%-properties%*")
  local missing_el = {}
  for sel in pairs(require("dbdash.css.ua")) do
    for piece in (sel .. ","):gmatch("([^,]*),") do
      for tag in piece:gmatch("([%a][%w-]*)") do
        if not piece:find("%." .. tag) and not elements:find(tag, 1, true) then
          missing_el[#missing_el + 1] = tag
        end
      end
    end
  end
  eq(missing_el, {})
end

T["help tags build and lines fit in 78 columns"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/doc", "p")
  for _, f in ipairs({ "dbdash.txt", "dbdash-schema.txt" }) do
    vim.fn.writefile(vim.fn.readfile("doc/" .. f), dir .. "/doc/" .. f)
  end
  vim.cmd("helptags " .. vim.fn.fnameescape(dir .. "/doc")) -- raises on duplicate tags
  local long = {}
  for _, f in ipairs({ "dbdash.txt", "dbdash-schema.txt" }) do
    for i, l in ipairs(vim.fn.readfile("doc/" .. f)) do
      if vim.fn.strdisplaywidth(l) > 78 then
        long[#long + 1] = ("%s:%d"):format(f, i)
      end
    end
  end
  eq(long, {})
end

T["doc/dbdash-schema.txt is generated from the current schema (make doc)"] = function()
  local gen = dofile("scripts/schema_doc.lua")
  local want = gen.render(gen.read(gen.SCHEMA))
  local have = gen.read(gen.HELP):gsub("\r\n", "\n")
  if have ~= want then
    error(gen.HELP .. " is out of date with " .. gen.SCHEMA .. ": run make doc", 0)
  end
end

T["doc/tags is the help tags of the current help files (make doc)"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/doc", "p")
  for _, f in ipairs({ "dbdash.txt", "dbdash-schema.txt" }) do
    vim.fn.writefile(vim.fn.readfile("doc/" .. f), dir .. "/doc/" .. f)
  end
  vim.cmd("helptags " .. vim.fn.fnameescape(dir .. "/doc"))
  local function lines(path)
    return vim.tbl_map(function(l)
      return (l:gsub("\r$", ""))
    end, vim.fn.readfile(path))
  end
  if not vim.deep_equal(lines("doc/tags"), lines(dir .. "/doc/tags")) then
    error("doc/tags is out of date with the help files: run make doc", 0)
  end
end

T["every schema field has a help tag that jumps to it"] = function()
  local gen = dofile("scripts/schema_doc.lua")
  local schema = vim.split(gen.read(gen.SCHEMA):gsub("\r\n", "\n"), "\n")
  local tags = gen.tags(schema)
  local help = gen.read(gen.HELP)
  -- a sample of each kind, and every top-level field and definition
  for _, t in ipairs({
    "dbdash-schema-panels",
    "dbdash-schema-style.renderer",
    "dbdash-schema-def-show",
    "dbdash-schema-show.interval",
    "dbdash-schema-database.options.lib_path",
    "dbdash-schema-show.column_list.alias",
    "dbdash-schema-query.sql",
  }) do
    eq({ t, help:find("*" .. t .. "* >yaml", 1, true) ~= nil }, { t, true })
  end
  local top, defs = {}, {}
  local section
  for i, l in ipairs(schema) do
    section = l:match("^(%w+):") or section
    local key = l:match("^  ([%w_]+):")
    if key and section == "properties" then
      top[#top + 1] = { tags[i], "dbdash-schema-" .. key }
    elseif key and section == "definitions" then
      defs[#defs + 1] = { tags[i], "dbdash-schema-def-" .. key }
    end
  end
  for _, pair in ipairs(vim.list_extend(top, defs)) do
    eq(pair[1], pair[2])
  end
  eq(#top > 10, true)
end

T["references lead somewhere: :help tags, |links| and ARCHITECTURE.md sections"] = function()
  local tags = {}
  for _, f in ipairs({ "doc/dbdash.txt", "doc/dbdash-schema.txt" }) do
    for tag in table.concat(vim.fn.readfile(f), "\n"):gmatch("%*(dbdash[%w_.:-]*)%*") do
      tags[tag] = true
    end
  end
  local anchors = {}
  for _, l in ipairs(vim.fn.readfile("ARCHITECTURE.md")) do
    local h = l:match("^## (.+)$")
    if h then
      anchors[h:lower():gsub("[^%w%- ]", ""):gsub(" ", "-")] = true
    end
  end
  local files = vim.fn.globpath("lua", "**/*.lua", false, true)
  vim.list_extend(files, vim.fn.globpath("example", "**/*.yaml", false, true))
  vim.list_extend(files, { "README.md", "doc/dbdash.txt", "ARCHITECTURE.md" })
  local nowhere = {}
  for _, f in ipairs(files) do
    local text = table.concat(vim.fn.readfile(f), "\n")
    for tag in text:gmatch(":help (dbdash[%w_.:-]*[%w_])") do
      if not tags[tag] then
        nowhere[#nowhere + 1] = f .. ": " .. tag
      end
    end
    for tag in text:gmatch("|(dbdash[%w_.:-]*)|") do
      if not tags[tag] then
        nowhere[#nowhere + 1] = f .. ": " .. tag
      end
    end
    for anchor in text:gmatch("ARCHITECTURE%.md#([%w%-]+)") do
      if not anchors[anchor] then
        nowhere[#nowhere + 1] = f .. ": #" .. anchor
      end
    end
  end
  table.sort(nowhere)
  eq(nowhere, {})
end

return T
