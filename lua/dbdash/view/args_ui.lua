-- Interactive argument input (:help dbdash-arguments) on top of vim.ui.input / vim.ui.select.
local args = require("dbdash.args")

local M = {}

local function prompt_for(spec)
  local p = (spec.key or spec.name) .. " (" .. spec.type .. ")"
  if spec.description then
    p = p .. " " .. spec.description
  end
  return p .. ": "
end

local notify = require("dbdash.view.notifier").error

---Ask for one value. `cb(value)` gets the parsed value, or nil when cancelled.
---@param spec dbdash.ArgSpec
---@param current any current value (pre-filled)
---@param cb fun(value: any)
function M.ask(spec, current, cb)
  local function input()
    vim.ui.input({ prompt = prompt_for(spec), default = args.format_value(current) }, function(text)
      if text == nil then
        return cb(nil)
      end
      local ok, v = pcall(args.parse_value, spec, text)
      if not ok then
        notify(v.message or tostring(v))
        return vim.schedule(input)
      end
      cb(v)
    end)
  end
  local choices = spec.choices
  if choices and #choices > 0 and spec.type ~= "list" and spec.type ~= "map" then
    local items = vim.deepcopy(choices)
    items[#items + 1] = "Other…"
    vim.ui.select(items, {
      prompt = prompt_for(spec),
      format_item = function(item)
        return item == "Other…" and item or args.format_value(item)
      end,
    }, function(choice, idx)
      if choice == nil then
        return cb(nil)
      elseif idx == #items then
        return input()
      end
      local ok, v = pcall(args.parse_value, spec, args.format_value(choice))
      cb(ok and v or choice)
    end)
  else
    input()
  end
end

---Ask for several arguments in order, storing answers in state.interactive.
---`done(ok)` is false when the user cancelled.
---@param specs dbdash.ArgSpec[]
---@param state dbdash.ArgState
---@param done fun(ok: boolean)
function M.ask_all(specs, state, done)
  local i = 0
  local function step()
    i = i + 1
    local spec = specs[i]
    if not spec then
      return done(true)
    end
    M.ask(spec, args.value(spec, state), function(v)
      if v == nil then
        return done(false)
      end
      state.interactive[spec.key or spec.name] = v
      vim.schedule(step)
    end)
  end
  step()
end

return M
