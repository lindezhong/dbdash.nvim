-- dbdash.nvim: database dashboards in Neovim. The entry point: setup(), the global
-- mappings and the Lua API (:help dbdash-api).
local M = {}

local options = require("dbdash.options")

-- The UI side of hooks the lower layers call: the trust prompt's View float.
require("dbdash.trust").viewer = function(...)
  return require("dbdash.view.trust").view(...)
end

-- The dashboard keys' actions are commands (the controller).
require("dbdash.dashboard.events"):on("action", function(...)
  require("dbdash.commands").action(...)
end)

-- Global mappings ---------------------------------------------------------------------------

M.MAPPINGS = {
  { name = "start", lhs = "<leader>ds", rhs = ":DbDashStart ", desc = "Start a dashboard" },
  {
    name = "refresh",
    lhs = "<leader>dr",
    rhs = "<Cmd>DbDashRestart<CR>",
    desc = "Refresh the dashboard",
  },
  { name = "stop", lhs = "<leader>dt", rhs = "<Cmd>DbDashStop<CR>", desc = "Stop the dashboard" },
  { name = "list", lhs = "<leader>dl", rhs = "<Cmd>DbDashList<CR>", desc = "List dashboards" },
  { name = "sidebar", lhs = "<leader>dd", rhs = "<Cmd>DbDash<CR>", desc = "Open the sidebar" },
}

---Mappings to define for the `mappings` option: { lhs, rhs, desc }[].
local function active_mappings()
  local m = options.current.mappings
  if m == false then
    return {}
  end
  local out = {}
  for _, def in ipairs(M.MAPPINGS) do
    local lhs = def.lhs
    if type(m) == "table" and m[def.name] ~= nil then
      lhs = m[def.name]
    end
    if lhs then
      out[#out + 1] = { lhs, def.rhs, def.desc }
    end
  end
  return out
end

---Define the global mappings unless the keys are already mapped by the user.
function M.set_mappings()
  for _, m in ipairs(active_mappings()) do
    if vim.fn.maparg(m[1], "n") == "" then
      vim.keymap.set("n", m[1], m[2], { desc = "dbdash: " .. m[3] })
    end
  end
end

---Remove the global mappings this plugin defined (found by their description).
function M.del_mappings()
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.desc and map.desc:find("^dbdash: ") then
      -- (pcall: a mapping the user already removed)
      pcall(vim.keymap.del, "n", map.lhs)
    end
  end
end

---@param opts dbdash.Options?
function M.setup(opts)
  local errors = options.set(opts)
  if #errors > 0 then
    vim.notify("dbdash setup: " .. table.concat(errors, "\n"), vim.log.levels.ERROR)
  end
  M.del_mappings()
  M.set_mappings()
end

-- Public API ------------------------------------------------------------------------------

---Write the changed argument values of running dashboards to `file` (:help
---dbdash-session-state).
function M.mksession(file)
  return require("dbdash.session").mksession(file)
end

---Load argument values written by mksession() from `file`.
function M.load_session(file)
  return require("dbdash.session").load_session(file)
end

---Start a dashboard. `tokens` are "name=value" arguments.
function M.start(path, tokens)
  return require("dbdash.view.dashboard").start(path, { tokens = tokens })
end

function M.stop(path)
  return require("dbdash.dashboard").stop(require("dbdash.dashboard").normalize(path))
end

---Run a query through the data layer: callback(err, resultset).
function M.query(url, query, opts, callback)
  return require("dbdash.db").query(url, query, opts, callback)
end

return M
