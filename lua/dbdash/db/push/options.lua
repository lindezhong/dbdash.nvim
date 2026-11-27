-- database.options of push sources: checked by type, unknown names are errors.
local dberr = require("dbdash.util.error")
local map = require("dbdash.util.map")

local M = {}

local function kind(v)
  if v == nil or v == vim.NIL then
    return "nil"
  elseif map.is_map(v) or (type(v) == "table" and next(v) ~= nil and not vim.islist(v)) then
    return "map"
  elseif type(v) == "table" then
    return "list"
  elseif type(v) == "number" and v == math.floor(v) then
    return "integer"
  end
  return type(v)
end

---Check `options` against `spec` ({ name = "string" | "list" | "map" | "integer" |
---"boolean" | fun(v): string? }); returns them with defaults filled in.
---@param scheme string for messages
function M.check(scheme, options, spec, defaults)
  local out = {}
  for k, v in pairs(options or {}) do
    local want = spec[k]
    if want == nil then
      local names = vim.tbl_keys(spec)
      table.sort(names)
      dberr.raise(
        "config",
        ("%s://: unknown option database.options.%s (known: %s)"):format(
          scheme,
          tostring(k),
          table.concat(names, ", ")
        )
      )
    end
    if v ~= vim.NIL then
      local err
      if type(want) == "function" then
        err = want(v)
      elseif kind(v) ~= want then
        err = ("must be a %s, got %s"):format(want, kind(v))
      end
      if err then
        dberr.raise("config", ("%s://: database.options.%s %s"):format(scheme, k, err))
      end
      out[k] = v
    end
  end
  for k, v in pairs(defaults or {}) do
    if out[k] == nil then
      out[k] = v
    end
  end
  return out
end

---A directory option: "~" expanded, relative to the config file's directory, must exist.
---Default: the config file's directory (else Neovim's current directory).
function M.dir(scheme, value, base_dir)
  local base = base_dir or vim.fn.getcwd()
  if value == nil then
    return vim.fs.normalize(base)
  end
  local p = vim.fs.normalize(vim.fn.expand(value))
  if not (p:sub(1, 1) == "/" or p:match("^%a:[/\\]")) then
    p = vim.fs.normalize(vim.fs.joinpath(base, p))
  end
  if vim.fn.isdirectory(p) == 0 then
    dberr.raise("config", ("%s://: database.options.cwd is not a directory: %s"):format(scheme, p))
  end
  return p
end

---Replace ${NAME} with the environment variable NAME ($${ is a literal "${"); raises a
---config error naming `what` when one is not set.
function M.expand_env(value, what)
  if type(value) ~= "string" then
    return value
  end
  return (
    value:gsub("(%$?)%${([%a_][%w_]*)}", function(escape, name)
      if escape == "$" then
        return "${" .. name .. "}"
      end
      local v = vim.uv.os_getenv(name)
      if v == nil then
        dberr.raise("config", ("%s: environment variable %s is not set"):format(what, name))
      end
      return v
    end)
  )
end

function M.delimiter(v)
  if type(v) ~= "string" or v == "" then
    return "must be a non-empty string"
  end
end

return M
