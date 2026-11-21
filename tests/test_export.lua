-- export.format: csv, tsv, json, markdown.
local export = require("dbdash.export")
local resultset = require("dbdash.db.resultset")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local NULL = vim.NIL
local rs = resultset.new({
  { name = "id", type = "integer" },
  { name = "name", type = "string" },
  { name = "note", type = "string" },
  { name = "score", type = "number" },
  { name = "ok", type = "boolean" },
  { name = "id", type = "integer" }, -- duplicate name
}, {
  { 1, "Alice", 'say "hi", ok', 2.5, true, 10 },
  { 2, "王小明", "a|b\nline2\tx", NULL, false, 20 },
})

T["csv: RFC 4180 quoting, NULL as empty"] = function()
  eq(
    export.format(rs, "csv"),
    'id,name,note,score,ok,id\n1,Alice,"say ""hi"", ok",2.5,true,10\n2,王小明,"a|b\nline2\tx",,false,20\n'
  )
end

T["tsv: tabs, newlines and backslashes escaped"] = function()
  eq(export.format(rs, "tsv"), 'id\tname\tnote\tscore\tok\tid\n1\tAlice\tsay "hi", ok\t2.5\ttrue\t10\n2\t王小明\ta|b\\nline2\\tx\t\tfalse\t20\n')
end

T["json: objects in column order, typed values, null, unique keys"] = function()
  local out = export.format(rs, "json")
  eq(out, table.concat({
    "[",
    '  {"id": 1, "name": "Alice", "note": "say \\"hi\\", ok", "score": 2.5, "ok": true, "id_2": 10},',
    '  {"id": 2, "name": "王小明", "note": "a|b\\nline2\\tx", "score": null, "ok": false, "id_2": 20}',
    "]",
  }, "\n") .. "\n")
  local decoded = vim.json.decode(out)
  eq({ #decoded, decoded[2].score, decoded[1].id_2 }, { 2, vim.NIL, 10 })
end

T["markdown: pipes escaped, newlines as <br>, numbers right-aligned"] = function()
  eq(export.format(rs, "markdown"), table.concat({
    "| id | name | note | score | ok | id |",
    "| ---: | --- | --- | ---: | --- | ---: |",
    '| 1 | Alice | say "hi", ok | 2.5 | true | 10 |',
    "| 2 | 王小明 | a\\|b<br>line2\tx |  | false | 20 |",
  }, "\n") .. "\n")
end

T["bytes, JSON values and 64-bit integers"] = function()
  local r = resultset.new(
    { { name = "b", type = "bytes" }, { name = "j", type = "json" }, { name = "n", type = "integer" } },
    { { "\1\255", { a = 1 }, 9007199254740993LL } }
  )
  eq(export.format(r, "csv"), 'b,j,n\n\\x01ff,"{""a"":1}",9007199254740993\n')
  eq(export.format(r, "json"), '[\n  {"b": "\\\\x01ff", "j": {"a":1}, "n": 9007199254740993}\n]\n')
end

T["empty result and unknown format"] = function()
  local r = resultset.new({ { name = "x", type = "integer" } }, {})
  eq(export.format(r, "csv"), "x\n")
  eq(export.format(r, "json"), "[\n]\n")
  eq(pcall(export.format, r, "xml"), false)
end

return T
