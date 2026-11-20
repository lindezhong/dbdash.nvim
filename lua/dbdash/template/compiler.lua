-- Template compiler: AST -> Lua source.
--
-- The generated chunk receives the runtime and returns `function(ctx, env, L)`, where
-- `ctx` holds template variables, `env` carries render options (dialect, autoescape) and
-- `L` records the current template line for error reporting.
--
-- Scoping follows Jinja: `set` at template level is visible for the rest of the template
-- (including after an `if`), a `for` body is its own scope, and a name that was never
-- assigned falls back to the context (`rt.v(local, ctx, name)` with rt.MISSING).
local errors = require("dbdash.template.errors")
local R = require("dbdash.template.runtime")

local M = {}

local BINOPS = {
  ["+"] = "add",
  ["-"] = "sub",
  ["*"] = "mul",
  ["/"] = "div",
  ["//"] = "floordiv",
  ["%"] = "mod",
  ["**"] = "pow",
  ["~"] = "concat",
}

local METHODS = {}
for _, m in ipairs(R.METHOD_NAMES) do
  METHODS[m] = true
end

local C = {}
C.__index = C

function C:emit(s)
  self.buf[#self.buf + 1] = string.rep("  ", self.depth) .. s
end

function C:tmp()
  self.n = self.n + 1
  return "v" .. self.n
end

function C:fail(node, msg, ...)
  errors.syntax(node.line, node.col, msg, ...)
end

function C:lookup(name)
  for i = #self.scopes, 1, -1 do
    local b = self.scopes[i][name]
    if b then
      return b
    end
  end
end

local function const(v)
  if v == vim.NIL then
    return "rt.NONE"
  elseif type(v) == "number" then
    if v ~= v then
      return "(0/0)"
    elseif v == math.huge then
      return "math.huge"
    elseif v == -math.huge then
      return "(-math.huge)"
    end
    return ("%.17g"):format(v)
  elseif type(v) == "string" then
    return (("%q"):format(v):gsub("\\\n", "\\n"))
  end
  return tostring(v)
end

function C:list(nodes)
  local parts = {}
  for i, n in ipairs(nodes) do
    parts[i] = self:expr(n)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function C:kwargs(kws)
  local parts = {}
  for i, kv in ipairs(kws) do
    parts[i] = ("[%q] = %s"):format(kv[1], self:expr(kv[2]))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

---Compile an expression to a Lua expression string.
function C:expr(n)
  local k = n.k
  if k == "Const" then
    return const(n.v)
  elseif k == "Name" then
    local b = self:lookup(n.name)
    if b then
      return b.sure and b.lua or ("rt.v(%s, ctx, %q)"):format(b.lua, n.name)
    end
    return ("rt.lookup(ctx, %q)"):format(n.name)
  elseif k == "List" then
    return self:list(n.items)
  elseif k == "Dict" then
    local flat = {}
    for _, kv in ipairs(n.pairs) do
      flat[#flat + 1] = self:expr(kv[1])
      flat[#flat + 1] = self:expr(kv[2])
    end
    return "rt.dict({" .. table.concat(flat, ", ") .. "})"
  elseif k == "Getattr" then
    return ("rt.getattr(%s, %q)"):format(self:expr(n.obj), n.name)
  elseif k == "Getitem" then
    return ("rt.getitem(%s, %s)"):format(self:expr(n.obj), self:expr(n.key))
  elseif k == "Call" then
    local fn = n.fn
    if fn.k == "Getattr" then
      if not METHODS[fn.name] then
        self:fail(
          n,
          "calling '.%s()' is not supported (allowed methods: %s)",
          fn.name,
          table.concat(R.METHOD_NAMES, ", ")
        )
      end
      if #n.kwargs > 0 then
        self:fail(n, "keyword arguments are not supported for methods")
      end
      local args = { self:expr(fn.obj), ("%q"):format(fn.name) }
      for _, a in ipairs(n.args) do
        args[#args + 1] = self:expr(a)
      end
      return "rt.method(" .. table.concat(args, ", ") .. ")"
    end
    return ("rt.call(%s, %s, %s)"):format(self:expr(fn), self:list(n.args), self:kwargs(n.kwargs))
  elseif k == "Filter" then
    if not R.filters[n.name] then
      self:fail(n, "No filter named '%s'.", n.name)
    end
    return ("rt.filter(env, %q, %s, %s, %s)"):format(
      n.name,
      self:expr(n.node),
      self:list(n.args),
      self:kwargs(n.kwargs)
    )
  elseif k == "Test" then
    if not R.tests[n.name] then
      self:fail(n, "No test named '%s'.", n.name)
    end
    local e = ("rt.test(env, %q, %s, %s)"):format(n.name, self:expr(n.node), self:list(n.args))
    return n.neg and ("(not " .. e .. ")") or e
  elseif k == "Neg" then
    return ("rt.neg(%s)"):format(self:expr(n.node))
  elseif k == "Pos" then
    return ("rt.pos(%s)"):format(self:expr(n.node))
  elseif k == "Bin" then
    return ("rt.%s(%s, %s)"):format(BINOPS[n.op], self:expr(n.l), self:expr(n.r))
  elseif k == "Compare" then
    if #n.ops == 1 then
      return ("rt.cmp(%q, %s, %s)"):format(n.ops[1].op, self:expr(n.first), self:expr(n.ops[1].expr))
    end
    local parts = { "(function() local a = " .. self:expr(n.first) }
    for i, o in ipairs(n.ops) do
      parts[#parts + 1] = ("local b = %s"):format(self:expr(o.expr))
      if i < #n.ops then
        parts[#parts + 1] = ("if not rt.cmp(%q, a, b) then return false end a = b"):format(o.op)
      else
        parts[#parts + 1] = ("return rt.cmp(%q, a, b)"):format(o.op)
      end
    end
    return table.concat(parts, " ") .. " end)()"
  elseif k == "And" then
    return ("(function() local a = %s if not rt.truthy(a) then return a end return %s end)()"):format(
      self:expr(n.l),
      self:expr(n.r)
    )
  elseif k == "Or" then
    return ("(function() local a = %s if rt.truthy(a) then return a end return %s end)()"):format(
      self:expr(n.l),
      self:expr(n.r)
    )
  elseif k == "Not" then
    return ("(not rt.truthy(%s))"):format(self:expr(n.node))
  elseif k == "Cond" then
    -- Without else, Jinja yields a lenient Undefined (renders as "") even in strict mode.
    local b = n.b and self:expr(n.b) or '""'
    return ("(function() if rt.truthy(%s) then return %s end return %s end)()"):format(
      self:expr(n.test),
      self:expr(n.a),
      b
    )
  end
  error("unknown expression node " .. tostring(k))
end

---Names assigned by `set` in this scope (descends into if/else and for-else, not loop bodies).
local function collect_sets(body, out, seen)
  out, seen = out or {}, seen or {}
  for _, st in ipairs(body) do
    if st.k == "Set" then
      for _, name in ipairs(st.targets) do
        if not seen[name] then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    elseif st.k == "If" then
      for _, br in ipairs(st.branches) do
        collect_sets(br.body, out, seen)
      end
      if st.else_ then
        collect_sets(st.else_, out, seen)
      end
    elseif st.k == "For" and st.else_ then
      collect_sets(st.else_, out, seen)
    end
  end
  return out
end

---Open a scope and pre-declare locals for every `set` in `body`.
function C:open_scope(body, bindings)
  local scope = bindings or {}
  for _, name in ipairs(collect_sets(body)) do
    local outer = self:lookup(name)
    local lua = self:tmp()
    self:emit(("local %s = %s"):format(lua, outer and outer.lua or "rt.MISSING"))
    scope[name] = { lua = lua, sure = false }
  end
  self.scopes[#self.scopes + 1] = scope
end

function C:close_scope()
  self.scopes[#self.scopes] = nil
end

function C:line(n)
  self:emit(("L.l = %d"):format(n.line))
end

function C:body(stmts)
  for _, st in ipairs(stmts) do
    self:stmt(st)
  end
end

function C:stmt(st)
  local k = st.k
  if k == "Data" then
    self:emit(("o[#o + 1] = %s"):format(const(st.v)))
  elseif k == "Output" then
    self:line(st)
    self:emit(("o[#o + 1] = rt.out(env, %s)"):format(self:expr(st.expr)))
  elseif k == "If" then
    self:if_chain(st, 1)
  elseif k == "For" then
    self:line(st)
    local it, n, i = self:tmp(), self:tmp(), self:tmp()
    self:emit("do")
    self.depth = self.depth + 1
    self:emit(("local %s = rt.iter(%s)"):format(it, self:expr(st.iter)))
    self:emit(("local %s = #%s"):format(n, it))
    self:emit(("if %s == 0 then"):format(n))
    self.depth = self.depth + 1
    if st.else_ then
      self:body(st.else_)
    end
    self.depth = self.depth - 1
    self:emit("else")
    self.depth = self.depth + 1
    self:emit(("for %s = 1, %s do"):format(i, n))
    self.depth = self.depth + 1
    local bindings = {}
    local loopvar = self:tmp()
    self:emit(("local %s = rt.loop(%s, %s)"):format(loopvar, i, n))
    bindings.loop = { lua = loopvar, sure = true }
    local targets = {}
    for j, name in ipairs(st.targets) do
      targets[j] = self:tmp()
      bindings[name] = { lua = targets[j], sure = true }
    end
    if #targets == 1 then
      self:emit(("local %s = %s[%s]"):format(targets[1], it, i))
    else
      self:emit(
        ("local %s = rt.unpack(%s[%s], %d)"):format(table.concat(targets, ", "), it, i, #targets)
      )
    end
    self:open_scope(st.body, bindings)
    self:body(st.body)
    self:close_scope()
    self.depth = self.depth - 1
    self:emit("end")
    self.depth = self.depth - 1
    self:emit("end")
    self.depth = self.depth - 1
    self:emit("end")
  elseif k == "Set" then
    self:line(st)
    local lhs = {}
    for j, name in ipairs(st.targets) do
      local b = self.scopes[#self.scopes][name]
      lhs[j] = b.lua
    end
    if #lhs == 1 then
      self:emit(("%s = %s"):format(lhs[1], self:expr(st.expr)))
    else
      self:emit(("%s = rt.unpack(%s, %d)"):format(table.concat(lhs, ", "), self:expr(st.expr), #lhs))
    end
  else
    error("unknown statement node " .. tostring(k))
  end
end

function C:if_chain(st, idx)
  local br = st.branches[idx]
  self:emit(("L.l = %d"):format(br.line))
  self:emit(("if rt.truthy(%s) then"):format(self:expr(br.test)))
  self.depth = self.depth + 1
  self:body(br.body)
  self.depth = self.depth - 1
  if idx < #st.branches then
    self:emit("else")
    self.depth = self.depth + 1
    self:if_chain(st, idx + 1)
    self.depth = self.depth - 1
  elseif st.else_ then
    self:emit("else")
    self.depth = self.depth + 1
    self:body(st.else_)
    self.depth = self.depth - 1
  end
  self:emit("end")
end

---Compile an AST body into Lua source.
---@param body table[]
---@return string
function M.compile(body)
  local c = setmetatable({ buf = {}, depth = 0, n = 0, scopes = {} }, C)
  c:emit("local rt = ...")
  c:emit("return function(ctx, env, L)")
  c.depth = 1
  c:emit("local o = {}")
  c:open_scope(body)
  c:body(body)
  c:close_scope()
  c:emit("return table.concat(o)")
  c.depth = 0
  c:emit("end")
  return table.concat(c.buf, "\n")
end

return M
