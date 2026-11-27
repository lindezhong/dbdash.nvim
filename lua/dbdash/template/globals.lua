-- Jinja's global functions besides range(): namespace(), dict(), cycler(), joiner() and
-- lipsum(), with their objects.
local R = require("dbdash.template.runtime")
local map = require("dbdash.util.map")
local errors = require("dbdash.template.errors")

local M = {}

local raise = errors.raise

-- namespace(): attributes that {% set ns.x = v %} can change (from any scope) ----------

local Namespace = {}
Namespace.__index = Namespace

R.getattr_hook[Namespace] = function(ns, name)
  return ns.attrs[name]
end
R.repr_hook[Namespace] = function(ns)
  return "<Namespace " .. R.repr(ns.attrs) .. ">"
end

---{% set obj.attr = value %}: only namespaces take attributes.
function R.set_attr(obj, name, value)
  R.check(obj)
  if getmetatable(obj) ~= Namespace then
    raise("value", "cannot assign attribute on non-namespace object")
  end
  map.set(obj.attrs, name, value)
end

---Keyword arguments as a mapping, in the order they were written.
local function kw_map(kwargs, into)
  local out = into or map.new()
  for _, k in ipairs(R.kw_keys(kwargs)) do
    map.set(out, k, kwargs[k])
  end
  return out
end

---A mapping from dict()'s arguments: a mapping or (key, value) pairs, then keywords.
local function dict_of(fname, args, kwargs)
  if #args > 1 then
    raise("type", "%s expected at most 1 argument, got %d", fname, #args)
  end
  local out = map.new()
  local first = args[1]
  if first ~= nil then
    if map.is_map(first) then
      for k, v in map.pairs(first) do
        map.set(out, k, v)
      end
    elseif getmetatable(first) == Namespace then
      for k, v in map.pairs(first.attrs) do
        map.set(out, k, v)
      end
    else
      for _, kv in ipairs(R.iter(first)) do
        local k, v = R.unpack(kv, 2)
        map.set(out, R.key_of(k), v)
      end
    end
  end
  return kw_map(kwargs, out)
end

local G = {}

G.namespace = function(args, kwargs)
  local ns = setmetatable({ attrs = dict_of("namespace", args, kwargs) }, Namespace)
  R.typenames[ns] = "Namespace"
  return ns
end

G.dict = function(args, kwargs)
  return dict_of("dict", args, kwargs)
end

-- cycler(a, b, ...): next(), reset(), current -----------------------------------------------

local Cycler = {}
Cycler.__index = Cycler

R.getattr_hook[Cycler] = function(c, name)
  if name == "current" then
    return c.items[c.pos]
  elseif name == "items" then
    return c.items
  elseif name == "next" then
    return function()
      local v = c.items[c.pos]
      c.pos = c.pos % #c.items + 1
      return v
    end
  elseif name == "reset" then
    return function()
      c.pos = 1
      return R.NONE
    end
  end
end

G.cycler = function(args, kwargs)
  if next(kwargs) then
    raise("type", "cycler() takes no keyword arguments")
  end
  if #args == 0 then
    raise("type", "at least one item has to be provided")
  end
  local c = setmetatable({ items = vim.list_extend({}, args), pos = 1 }, Cycler)
  R.typenames[c] = "Cycler"
  return c
end

-- joiner(sep): "" the first time, then sep ---------------------------------------------------

G.joiner = function(args, kwargs)
  local sep = require("dbdash.template.bind").bind("joiner", args, kwargs, { { "sep", ", " } })
  local used = false
  return function()
    if not used then
      used = true
      return ""
    end
    return sep
  end
end

-- lipsum(n=5, html=True, min=20, max=100): lorem ipsum paragraphs (as Jinja) ----------------

local WORDS = vim.split(
  table.concat({
    "a ac accumsan ad adipiscing aenean aliquam aliquet amet ante aptent arcu at auctor",
    "augue bibendum blandit class commodo condimentum congue consectetuer consequat",
    "conubia convallis cras cubilia cum curabitur curae cursus dapibus diam dictum",
    "dictumst dignissim dis dolor donec dui duis egestas eget eleifend elementum elit",
    "enim erat eros est et etiam eu euismod facilisi facilisis fames faucibus felis",
    "fermentum feugiat fringilla fusce gravida habitant habitasse hac hendrerit hymenaeos",
    "iaculis id imperdiet in inceptos integer interdum ipsum justo lacinia lacus laoreet",
    "lectus leo libero ligula litora lobortis lorem luctus maecenas magna magnis",
    "malesuada massa mattis mauris metus mi molestie mollis montes morbi mus nam nascetur",
    "natoque nec neque netus nibh nisi nisl non nonummy nostra nulla nullam nunc odio",
    "orci ornare parturient pede pellentesque penatibus per pharetra phasellus placerat",
    "platea porta porttitor posuere potenti praesent pretium primis proin pulvinar purus",
    "quam quis quisque rhoncus ridiculus risus rutrum sagittis sapien scelerisque sed sem",
    "semper senectus sit sociis sociosqu sodales sollicitudin suscipit suspendisse taciti",
    "tellus tempor tempus tincidunt torquent tortor tristique turpis ullamcorper ultrices",
    "ultricies urna ut varius vehicula vel velit venenatis vestibulum vitae vivamus",
    "viverra volutpat vulputate",
  }, " "),
  " "
)

G.lipsum = function(args, kwargs)
  local n, html, min, max = require("dbdash.template.bind").bind(
    "lipsum",
    args,
    kwargs,
    { { "n", 5 }, { "html", true }, { "min", 20 }, { "max", 100 } }
  )
  local function rand(a, b) -- randrange(a, b)
    return math.random(a, b - 1)
  end
  local result = {}
  for _ = 1, n do
    local next_cap, last_comma, last_stop = true, 0, 0
    local last
    local p = {}
    for idx = 0, rand(min, max) - 1 do
      local word
      repeat
        word = WORDS[math.random(#WORDS)]
      until word ~= last
      last = word
      if next_cap then
        word = word:sub(1, 1):upper() .. word:sub(2)
        next_cap = false
      end
      if idx - rand(3, 8) > last_comma then
        last_comma = idx
        last_stop = last_stop + 2
        word = word .. ","
      end
      if idx - rand(10, 20) > last_stop then
        last_comma, last_stop = idx, idx
        word = word .. "."
        next_cap = true
      end
      p[#p + 1] = word
    end
    local s = table.concat(p, " ")
    if s:sub(-1) == "," then
      s = s:sub(1, -2) .. "."
    elseif s:sub(-1) ~= "." then
      s = s .. "."
    end
    result[#result + 1] = s
  end
  if not R.truthy(html) then
    return table.concat(result, "\n\n")
  end
  return R.safe(table.concat(
    vim.tbl_map(function(x)
      return "<p>" .. R.html_escape(x) .. "</p>"
    end, result),
    "\n"
  ))
end

function M.install()
  for k, v in pairs(G) do
    R.globals[k] = v
  end
end

return M
