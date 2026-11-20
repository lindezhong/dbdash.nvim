-- Shared test helpers.
local M = {}

---Serialize render output as text + highlight markers, readable in diffs:
---  each output line is written as "│<text>", followed by "  ^ <s>-<e> <Group>" lines.
---@param out dbdash.render.Output
---@return string
function M.serialize(out)
  local by_row = {}
  for _, h in ipairs(out.hl) do
    by_row[h.row] = by_row[h.row] or {}
    table.insert(by_row[h.row], h)
  end
  local buf = {}
  for i, line in ipairs(out.lines) do
    buf[#buf + 1] = "│" .. line
    local hs = by_row[i - 1] or {}
    table.sort(hs, function(a, b)
      return a.col_s < b.col_s or (a.col_s == b.col_s and a.group < b.group)
    end)
    for _, h in ipairs(hs) do
      buf[#buf + 1] = ("  ^ %d-%d %s"):format(h.col_s, h.col_e, h.group)
    end
  end
  return table.concat(buf, "\n") .. "\n"
end

---Compare output with tests/golden/<name>.txt. UPDATE_GOLDEN=1 rewrites the file.
---On mismatch the actual output is saved next to it as .actual.
function M.golden(name, out)
  local path = "tests/golden/" .. name .. ".txt"
  local actual = M.serialize(out)
  if vim.env.UPDATE_GOLDEN == "1" or vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(actual, "\n", { plain = true }), path, "b")
    if vim.env.UPDATE_GOLDEN ~= "1" then
      error("golden file created, review and re-run: " .. path)
    end
    return
  end
  local expected = table.concat(vim.fn.readfile(path, "b"), "\n")
  if expected ~= actual then
    vim.fn.writefile(vim.split(actual, "\n", { plain = true }), path:gsub("%.txt$", ".actual"), "b")
    error(("golden mismatch for %s (see %s, update with UPDATE_GOLDEN=1)"):format(
      path,
      path:gsub("%.txt$", ".actual")
    ))
  end
end

return M
