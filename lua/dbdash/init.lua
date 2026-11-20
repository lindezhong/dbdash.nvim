-- dbdash.nvim: database dashboards in Neovim.
local M = {}

---@class dbdash.Options
---@field mappings boolean global <leader>d* mappings (default true)
---@field countdown_interval integer ms between countdown updates (default 10000)
---@field countdown_position "right_align"|"eol"|"overlay"
---@field styles table<string, { renderer: string?, canvas: string? }> per chart type defaults
---@field ticks string tick algorithm ("nice" | "linear")
---@field register table<string, any> custom render implementations ("chart/bar/mine", ...)
local defaults = {
  mappings = true,
  countdown_interval = 10000,
  countdown_position = "right_align",
  styles = {},
  ticks = "nice",
  register = {},
}

---@type dbdash.Options
M.options = vim.deepcopy(defaults)

M.MAPPINGS = {
  { "<leader>ds", ":DbDashStart ", "Start a dashboard" },
  { "<leader>dr", "<Cmd>DbDashRestart<CR>", "Refresh the dashboard" },
  { "<leader>dt", "<Cmd>DbDashStop<CR>", "Stop the dashboard" },
  { "<leader>dl", "<Cmd>DbDashList<CR>", "List dashboards" },
  { "<leader>dd", "<Cmd>DbDash<CR>", "Open the sidebar" },
}

---Define the global mappings unless the keys are already mapped by the user.
function M.set_mappings()
  for _, m in ipairs(M.MAPPINGS) do
    if vim.fn.maparg(m[1], "n") == "" then
      vim.keymap.set("n", m[1], m[2], { desc = "dbdash: " .. m[3] })
    end
  end
end

---Remove the global mappings this plugin defined.
function M.del_mappings()
  for _, m in ipairs(M.MAPPINGS) do
    local info = vim.fn.maparg(m[1], "n", false, true)
    if info.desc and info.desc:find("^dbdash: ") then
      pcall(vim.keymap.del, "n", m[1])
    end
  end
end

---@param opts dbdash.Options?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  if M.options.mappings == false then
    M.del_mappings()
  else
    M.set_mappings()
  end
  for name, impl in pairs(M.options.register or {}) do
    local ok, registry = pcall(require, "dbdash.render.registry")
    if ok then
      registry.register(name, impl)
    end
  end
end

-- Public API ------------------------------------------------------------------------------

---Start a dashboard. `tokens` are "name=value" arguments.
function M.start(path, tokens)
  return require("dbdash.scheduler").start(path, { tokens = tokens })
end

function M.stop(path)
  return require("dbdash.scheduler").stop(require("dbdash.scheduler").normalize(path))
end

---Run a query through the data layer: callback(err, resultset).
function M.query(url, query, opts, callback)
  return require("dbdash.db").query(url, query, opts, callback)
end

return M
