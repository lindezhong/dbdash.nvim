-- Passwords that are not written in a config file:
--   * ${NAME} in a database URL is replaced by the environment variable NAME ($${ is "${");
--   * database.password_cmd runs a command and uses its output;
--   * stdpath("data")/dbdash/passwords.json maps URLs without passwords to passwords.
-- A password in the URL wins over password_cmd, which wins over passwords.json.
local async = require("dbdash.util.async")
local dberr = require("dbdash.db.error")

local M = {}

---Replace ${NAME} with environment variables; "$${" stays a literal "${".
---@param s string
---@return string? expanded, string? err
function M.expand_env(s)
  local missing
  local out = s:gsub("(%$?)%${([^}]*)}", function(escape, name)
    if escape == "$" then
      return "${" .. name .. "}"
    end
    if not name:match("^[%a_][%w_]*$") then
      missing = missing or ("invalid environment variable name %q"):format(name)
      return ""
    end
    local v = vim.uv.os_getenv(name)
    if v == nil then
      missing = missing or ("environment variable %s is not set"):format(name)
      return ""
    end
    -- Percent-encode characters that would change the URL structure.
    return (v:gsub("[%%@:/?#&=%s]", function(c)
      return ("%%%02X"):format(c:byte())
    end))
  end)
  if missing then
    return nil, missing
  end
  return out
end

-- passwords.json ----------------------------------------------------------------------------

---@return string
function M.file()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "dbdash", "passwords.json")
end

local file_cache = { path = nil, mtime = nil, data = nil }

---Contents of passwords.json (cached by modification time); nil when there is none.
---@return table<string, string>?, string? err
function M.load_file()
  local path = M.file()
  local st = vim.uv.fs_stat(path)
  if not st then
    file_cache = {}
    return nil
  end
  local mtime = st.mtime.sec .. "." .. st.mtime.nsec
  if file_cache.path == path and file_cache.mtime == mtime then
    return file_cache.data, file_cache.err
  end
  local data, err
  local f = io.open(path, "r")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if ok and type(decoded) == "table" and not vim.islist(decoded) then
      data = decoded
    elseif ok and type(decoded) == "table" and next(decoded) == nil then
      data = {}
    else
      err = ("%s is not a JSON object of url -> password"):format(path)
    end
  end
  file_cache = { path = path, mtime = mtime, data = data, err = err }
  return data, err
end

---Keys looked up in passwords.json for a parsed URL, most specific first:
---scheme://user@host:port/db, scheme://user@host:port, scheme://user@host.
---@param info dbdash.db.Url
---@return string[]
function M.keys(info)
  local user = info.user and info.user ~= "" and (info.user .. "@") or ""
  local host = info.host or ""
  if host:find(":", 1, true) then
    host = "[" .. host .. "]" -- IPv6
  end
  local base = info.scheme .. "://" .. user .. host
  local out = {}
  if info.port then
    if info.database then
      out[#out + 1] = base .. ":" .. info.port .. "/" .. info.database
    end
    out[#out + 1] = base .. ":" .. info.port
  end
  out[#out + 1] = base
  return out
end

---Password for `info` from passwords.json, if any.
---@param info dbdash.db.Url
---@return string?
function M.from_file(info)
  local data, err = M.load_file()
  if err then
    dberr.raise("config", err)
  end
  if not data then
    return nil
  end
  for _, k in ipairs(M.keys(info)) do
    if type(data[k]) == "string" then
      return data[k]
    end
  end
end

-- password_cmd ------------------------------------------------------------------------------

local cmd_cache = {} ---@type table<string, string>

local function cmd_key(cmd, info)
  return vim.inspect(cmd) .. "\0" .. table.concat(M.keys(info), "\0")
end

---Forget the cached password_cmd output for `info` (after an authentication failure).
function M.forget(cmd, info)
  cmd_cache[cmd_key(cmd, info)] = nil
end

---Run password_cmd inside a util.async task; the first line of its output is the password.
---@param cmd string|string[]
---@param info dbdash.db.Url
---@return string
function M.from_cmd(cmd, info)
  local key = cmd_key(cmd, info)
  if cmd_cache[key] then
    return cmd_cache[key]
  end
  local ok, res = pcall(async.await, function(cb)
    vim.system(
      require("dbdash.util.shell").argv(cmd),
      { text = true, timeout = info.connect_timeout },
      function(r)
        cb(r)
      end
    )
  end)
  if not ok then
    dberr.raise("connect", "password_cmd could not run: " .. tostring(res))
  end
  if res.code ~= 0 then
    local err = vim.trim(res.stderr or ""):gsub("\n.*", "")
    dberr.raise(
      "connect",
      ("password_cmd failed (exit %d)%s"):format(res.code, err ~= "" and (": " .. err) or "")
    )
  end
  local pw = (res.stdout or ""):gsub("\r?\n.*$", ""):gsub("\r$", "")
  if pw == "" then
    dberr.raise("connect", "password_cmd printed no password")
  end
  cmd_cache[key] = pw
  return pw
end

---Fill info.password when the URL has none: password_cmd, then passwords.json.
---Runs inside a util.async task.
---@param info dbdash.db.Url
---@param password_cmd string|string[]|nil
function M.fill(info, password_cmd)
  if info.password ~= nil or info.scheme:match("^sqlite") then
    return
  end
  if password_cmd then
    info.password = M.from_cmd(password_cmd, info)
  else
    info.password = M.from_file(info)
  end
end

return M
