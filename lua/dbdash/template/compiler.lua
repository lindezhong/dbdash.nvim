-- Template compiler: AST -> Lua source.
--
-- The generated chunk receives the runtime and returns `function(ctx, env, L, reg)`, where
-- `ctx` holds template variables, `env` carries render options (dialect, autoescape), `L`
-- records the current template line for error reporting and `reg` holds the blocks of a
-- template that extends another one (the child's blocks override the parent's).
--
-- Scoping follows Jinja: `set` at template level is visible for the rest of the template
-- (including after an `if`), a `for` body, `with`, macro, block and the body of a block
-- `set` / `filter` are scopes of their own, and a name that was never assigned falls back
-- to the context (`rt.v(local, ctx, name)` with rt.MISSING).
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

local C = {}
C.__index = C

function C:emit(s)
  self.buf[#self.buf + 1] = string.rep("  ", self.depth) .. s
end

function C:indent(d)
  self.depth = self.depth + d
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

-- AST helpers ------------------------------------------------------------------------------

---The statement lists inside statement `st` (bodies, branches, else).
local function bodies(st)
  local out = {}
  for _, key in ipairs({ "body", "else_" }) do
    if type(st[key]) == "table" then
      out[#out + 1] = st[key]
    end
  end
  for _, br in ipairs(st.branches or {}) do
    out[#out + 1] = br.body
  end
  return out
end

---Visit every statement in `body` (depth first); `fn(st)` returns false to skip its bodies.
local function walk(body, fn)
  for _, st in ipairs(body) do
    if fn(st) ~= false then
      for _, b in ipairs(bodies(st)) do
        walk(b, fn)
      end
    end
  end
end

---Names used in `node` (any AST table), not looking into nested macros and call blocks.
local function names_used(node, out)
  out = out or {}
  if type(node) ~= "table" then
    return out
  end
  if node.k == "Name" then
    out[node.name] = true
  end
  for key, v in pairs(node) do
    if
      type(v) == "table" and not ((node.k == "Macro" or node.k == "CallBlock") and key == "body")
    then
      if v.k ~= "Macro" then
        names_used(v, out)
      end
    end
  end
  return out
end

---True when `body` has a break or continue that belongs to the loop around it.
local function has_loop_control(body)
  local found = false
  walk(body, function(st)
    if st.k == "Break" or st.k == "Continue" then
      found = true
    end
    -- Not inside nested loops (their own), macros, call blocks or blocks.
    return not (st.k == "For" or st.k == "Macro" or st.k == "CallBlock" or st.k == "Block")
  end)
  return found
end

-- Expressions ------------------------------------------------------------------------------

function C:list(nodes)
  local parts = {}
  for i, n in ipairs(nodes) do
    parts[i] = self:expr(n)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function C:kwargs(kws)
  local parts, names = {}, {}
  for i, kv in ipairs(kws) do
    parts[i] = ("[%q] = %s"):format(kv[1], self:expr(kv[2]))
    names[i] = ("%q"):format(kv[1])
  end
  local t = "{" .. table.concat(parts, ", ") .. "}"
  if #kws > 1 then
    -- Keep the order (dict(a=1, b=2), a macro's kwargs).
    return ("rt.kw(%s, { %s })"):format(t, table.concat(names, ", "))
  end
  return t
end

---Positional and keyword arguments of a call, with *list and **mapping merged in.
function C:call_args(n)
  local args, kwargs = self:list(n.args), self:kwargs(n.kwargs or {})
  if n.dyn_args then
    args = ("rt.dyn_args(%s, %s)"):format(args, self:expr(n.dyn_args))
  end
  if n.dyn_kwargs then
    kwargs = ("rt.dyn_kwargs(%s, %s)"):format(kwargs, self:expr(n.dyn_kwargs))
  end
  return args, kwargs
end

---Compile an expression to a Lua expression string.
function C:expr(n)
  local k = n.k
  if k == "Const" then
    if n.float then
      return ("rt.float(%s)"):format(const(n.v))
    end
    return const(n.v)
  elseif k == "Raw" then
    return n.lua
  elseif k == "Name" then
    local b = self:lookup(n.name)
    if b then
      return b.sure and b.lua or ("rt.v(%s, ctx, %q)"):format(b.lua, n.name)
    elseif n.name == "self" then
      return "rt.self_ref(env, reg, ctx)" -- {{ self.block() }}
    end
    return ("rt.lookup(ctx, %q)"):format(n.name)
  elseif k == "List" then
    if n.tuple then
      return ("rt.tuple(%s)"):format(self:list(n.items))
    end
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
  elseif k == "Slice" then
    return ("rt.slice(%s, %s, %s, %s)"):format(
      self:expr(n.obj),
      n.start and self:expr(n.start) or "nil",
      n.stop and self:expr(n.stop) or "nil",
      n.step and self:expr(n.step) or "nil"
    )
  elseif k == "Call" then
    local fn = n.fn
    local args, kwargs = self:call_args(n)
    if fn.k == "Getattr" then
      -- obj.name(...): a macro of an imported module, or a method.
      return ("rt.call_attr(env, %s, %q, %s, %s)"):format(self:expr(fn.obj), fn.name, args, kwargs)
    end
    return ("rt.call(env, %s, %s, %s)"):format(self:expr(fn), args, kwargs)
  elseif k == "Filter" then
    if not R.filters[n.name] then
      self:fail(n, "No filter named '%s'.", n.name)
    end
    local args, kwargs = self:call_args(n)
    return ("rt.filter(env, %q, %s, %s, %s)"):format(n.name, self:expr(n.node), args, kwargs)
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
      return ("rt.cmp(%q, %s, %s)"):format(
        n.ops[1].op,
        self:expr(n.first),
        self:expr(n.ops[1].expr)
      )
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

---`value` passed through filters [{ name, args, kwargs }] (filter blocks, block set).
function C:apply_filters(value, filters)
  for _, f in ipairs(filters) do
    if not R.filters[f.name] then
      self:fail(f, "No filter named '%s'.", f.name)
    end
    local args, kwargs = self:call_args(f)
    value = ("rt.filter(env, %q, %s, %s, %s)"):format(f.name, value, args, kwargs)
  end
  return value
end

-- Scopes -----------------------------------------------------------------------------------

-- Names a template cannot assign: dashboards provide them (args.<name>, meta.<name>).
local RESERVED = { args = true, meta = true }

---Reject reserved names as set/for targets, macro names and parameters or import aliases.
local function check_reserved(body)
  local function bad(node, name)
    if RESERVED[name] then
      errors.syntax(
        node.line,
        node.col,
        "'%s' is reserved (dashboard %s) and cannot be assigned",
        name,
        name == "args" and "arguments" or "metadata"
      )
    end
  end
  walk(body, function(st)
    for _, name in ipairs(st.targets or {}) do
      bad(st, name)
    end
    for _, a in ipairs(st.assigns or {}) do
      for _, name in ipairs(a.targets) do
        bad(st, name)
      end
    end
    if st.k == "Macro" or st.k == "CallBlock" then
      if st.name then
        bad(st, st.name)
      end
      for _, p in ipairs(st.params) do
        bad(st, p.name)
      end
    elseif st.k == "Import" then
      bad(st, st.alias)
    elseif st.k == "FromImport" then
      for _, n in ipairs(st.names) do
        bad(st, n.alias)
      end
    end
  end)
end

---Names assigned in this scope: set, block set, macro, import (descends into if/else,
---for-else and autoescape, not into the other bodies: they are scopes of their own).
local function collect_sets(body, out, seen)
  out, seen = out or {}, seen or {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  for _, st in ipairs(body) do
    if st.k == "Set" or st.k == "SetBlock" then
      for _, name in ipairs(st.targets) do
        add(name)
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
    elseif st.k == "Autoescape" then
      collect_sets(st.body, out, seen)
    elseif st.k == "Macro" then
      add(st.name)
    elseif st.k == "Import" then
      add(st.alias)
    elseif st.k == "FromImport" then
      for _, n in ipairs(st.names) do
        add(n.alias)
      end
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

---Compile `body` in a scope of its own (with `bindings`).
function C:scoped_body(body, bindings)
  self:open_scope(body, bindings)
  self:body(body)
  self:close_scope()
end

---Lua table constructor of the template variables visible here (set, for, macro args):
---{ ["name"] = lua_var, ... } (values may be rt.MISSING).
function C:visible_locals()
  local fields, seen = {}, {}
  for i = #self.scopes, 1, -1 do
    for name, b in pairs(self.scopes[i]) do
      if not seen[name] and not name:match("^%$") then
        seen[name] = true
        fields[#fields + 1] = ("[%q] = %s"):format(name, b.lua)
      end
    end
  end
  table.sort(fields)
  return "{ " .. table.concat(fields, ", ") .. " }"
end

---Record a top-level variable for {% import %} (Jinja: names starting with "_" are private).
function C:export(name, lua)
  if #self.scopes == 1 and not name:match("^_") and not self.exported[name] then
    self.exported[name] = true
    self.exports[#self.exports + 1] = { name, lua }
  end
end

---Assign `value` (Lua expression) to the targets in the current scope.
function C:assign(targets, value)
  local lhs = {}
  for j, name in ipairs(targets) do
    local b = self.scopes[#self.scopes][name]
    lhs[j] = b.lua
    self:export(name, b.lua)
  end
  if #lhs == 1 then
    self:emit(("%s = %s"):format(lhs[1], value))
  else
    self:emit(("%s = rt.unpack(%s, %d)"):format(table.concat(lhs, ", "), value, #lhs))
  end
end

---The output of `body` (its own scope) as a Lua variable holding a string.
function C:capture(body)
  local v = self:tmp()
  self:emit(("local %s"):format(v))
  self:emit("do")
  self:indent(1)
  self:emit("local o = {}")
  self:scoped_body(body)
  self:emit(("%s = table.concat(o)"):format(v))
  self:indent(-1)
  self:emit("end")
  return v
end

---The context an import or include runs with: "with context" gives the caller's
---context and variables; otherwise nil (only the globals: a dashboard's args and meta).
function C:import_context(st)
  if st.with_context then
    return ("rt.layer(ctx, %s)"):format(self:visible_locals())
  end
  return "nil"
end

-- Statements -------------------------------------------------------------------------------

function C:line(n)
  self:emit(("L.l = %d"):format(n.line))
end

function C:body(stmts)
  for _, st in ipairs(stmts) do
    self:stmt(st)
  end
end

---Emit `target = rt.macro(...)`: a macro (or a call block's caller) with `params` and
---`body`. It takes varargs, kwargs and caller when its body uses those names.
function C:macro(target, name, params, body)
  local used = names_used(body)
  for _, p in ipairs(params) do
    if p.default then
      names_used(p.default, used)
    end
  end
  local flags = {
    catch_varargs = used.varargs and true or false,
    catch_kwargs = used.kwargs and true or false,
    caller = used.caller and true or false,
  }
  local names = {}
  for i, p in ipairs(params) do
    names[i] = ("%q"):format(p.name)
  end
  local flags_lua = ("{ catch_varargs = %s, catch_kwargs = %s, caller = %s }"):format(
    tostring(flags.catch_varargs),
    tostring(flags.catch_kwargs),
    tostring(flags.caller)
  )
  local args, kwargs, info = self:tmp(), self:tmp(), self:tmp()
  self:emit(("%s = rt.macro(%q, function(%s, %s, env)"):format(target, name, args, kwargs))
  self:indent(1)
  self:emit("local o = {}")
  -- Check the arguments; info has varargs, kwargs and caller.
  self:emit(
    ("local %s = rt.check_args(%q, %s, %s, { %s }, %s)"):format(
      info,
      name,
      args,
      kwargs,
      table.concat(names, ", "),
      flags_lua
    )
  )
  -- Bind parameters: positional, then keyword, then defaults.
  local bindings = {}
  for i, p in ipairs(params) do
    local lua = self:tmp()
    bindings[p.name] = { lua = lua, sure = true }
    self:emit(("local %s = %s[%d]"):format(lua, args, i))
    self:emit(("if %s == nil then %s = %s[%q] end"):format(lua, lua, kwargs, p.name))
    if p.default then
      -- Defaults see the earlier parameters.
      self.scopes[#self.scopes + 1] = bindings
      self:emit(("if %s == nil then %s = %s end"):format(lua, lua, self:expr(p.default)))
      self.scopes[#self.scopes] = nil
    else
      self:emit(
        ("if %s == nil then %s = rt.undef(%q) end"):format(
          lua,
          lua,
          ("'%s' is undefined (missing argument of macro %s)"):format(p.name, name)
        )
      )
    end
  end
  if flags.catch_varargs then
    bindings.varargs = { lua = info .. ".varargs", sure = true }
  end
  if flags.catch_kwargs then
    bindings.kwargs = { lua = info .. ".kwargs", sure = true }
  end
  if flags.caller then
    bindings.caller = { lua = info .. ".caller", sure = true }
  end
  local loops = self.loops
  self.loops = {} -- break / continue do not reach out of a macro
  self:scoped_body(body, bindings)
  self.loops = loops
  self:emit("return table.concat(o)")
  self:indent(-1)
  self:emit(("end, { %s }, %s)"):format(table.concat(names, ", "), flags_lua))
end

---The body of a for loop over the items in Lua variable `seq` (depth: Lua expression;
---rec: the recursive loop function or "nil").
function C:loop_body(st, seq, depth, rec)
  local it, n, i = self:tmp(), self:tmp(), self:tmp()
  self:emit(("local %s = rt.iter(%s)"):format(it, seq))
  local nt = #st.targets
  local function bind_targets(item)
    local bindings, targets = {}, {}
    for j, name in ipairs(st.targets) do
      targets[j] = self:tmp()
      bindings[name] = { lua = targets[j], sure = true }
    end
    if nt == 1 then
      self:emit(("local %s = %s"):format(targets[1], item))
    else
      self:emit(("local %s = rt.unpack(%s, %d)"):format(table.concat(targets, ", "), item, nt))
    end
    return bindings
  end
  if st.test then
    -- {% for x in xs if test %}: the items for which the test holds (loop.length counts
    -- those); the test sees the loop variables, not `loop`.
    local item = self:tmp()
    self:emit(("%s = rt.loop_filter(%s, function(%s)"):format(it, it, item))
    self:indent(1)
    local bindings = bind_targets(item)
    self.scopes[#self.scopes + 1] = bindings
    self:emit(("return rt.truthy(%s)"):format(self:expr(st.test)))
    self.scopes[#self.scopes] = nil
    self:indent(-1)
    self:emit("end)")
  end
  self:emit(("local %s = #%s"):format(n, it))
  self:emit(("if %s == 0 then"):format(n))
  self:indent(1)
  if st.else_ then
    self:body(st.else_)
  end
  self:indent(-1)
  self:emit("else")
  self:indent(1)
  local state = self:tmp()
  self:emit(("local %s = rt.loop_state(%s, %s, %s)"):format(state, it, depth, rec))
  local control = has_loop_control(st.body)
  local brk = control and self:tmp() or nil
  if brk then
    self:emit(("local %s = false"):format(brk))
  end
  self:emit(("for %s = 1, %s do"):format(i, n))
  self:indent(1)
  local loopvar = self:tmp()
  self:emit(("local %s = rt.loop(%s, %s)"):format(loopvar, state, i))
  local bindings = bind_targets(("%s[%s]"):format(it, i))
  bindings.loop = { lua = loopvar, sure = true }
  if control then
    -- continue leaves this repeat; break also sets brk and leaves the for loop after it.
    self:emit("repeat")
    self:indent(1)
  end
  self.loops[#self.loops + 1] = { brk = brk }
  self:scoped_body(st.body, bindings)
  self.loops[#self.loops] = nil
  if control then
    self:indent(-1)
    self:emit("until true")
    self:emit(("if %s then break end"):format(brk))
  end
  self:indent(-1)
  self:emit("end")
  self:indent(-1)
  self:emit("end")
end

function C:stmt(st)
  local k = st.k
  if k == "Data" then
    self:emit(("o[#o + 1] = %s"):format(const(st.v)))
  elseif k == "Lua" then
    self:line(st)
    -- The template variables visible here (set, for, macro arguments), for `vars`.
    self:emit(
      ("o[#o + 1] = rt.lua_block(env, %q, %d, function() return %s end)"):format(
        st.code,
        st.line,
        self:visible_locals()
      )
    )
  elseif k == "Output" then
    self:line(st)
    self:emit(("o[#o + 1] = rt.out(env, %s)"):format(self:expr(st.expr)))
  elseif k == "If" then
    self:if_chain(st, 1)
  elseif k == "For" then
    self:line(st)
    if st.recursive then
      -- A function, so that loop(items) renders the body again one level deeper.
      local rec = self:tmp()
      self:emit(("local %s"):format(rec))
      self:emit(("%s = function(seq, depth)"):format(rec))
      self:indent(1)
      self:emit("local o = {}")
      self:loop_body(st, "seq", "depth", rec)
      self:emit("return table.concat(o)")
      self:indent(-1)
      self:emit("end")
      self:emit(("o[#o + 1] = %s(%s, 1)"):format(rec, self:expr(st.iter)))
    else
      local seq = self:tmp()
      self:emit("do")
      self:indent(1)
      self:emit(("local %s = %s"):format(seq, self:expr(st.iter)))
      self:loop_body(st, seq, "1", "nil")
      self:indent(-1)
      self:emit("end")
    end
  elseif k == "Break" or k == "Continue" then
    local loop = self.loops[#self.loops]
    if not loop then
      self:fail(st, "'%s' outside of a loop", k:lower())
    end
    if k == "Break" then
      self:emit(("%s = true"):format(loop.brk))
    end
    self:emit("do break end")
  elseif k == "SetArg" then
    self:line(st)
    self:emit(("rt.set_arg(env, %q, %s)"):format(st.name, self:expr(st.expr)))
  elseif k == "SetAttr" then
    self:line(st)
    self:emit(("rt.set_attr(%s, %q, %s)"):format(self:expr(st.obj), st.attr, self:expr(st.expr)))
  elseif k == "Set" then
    self:line(st)
    self:assign(st.targets, self:expr(st.expr))
  elseif k == "SetBlock" then
    self:line(st)
    local v = self:capture(st.body)
    self:assign(st.targets, self:apply_filters(("rt.markup(env, %s)"):format(v), st.filters))
  elseif k == "FilterBlock" then
    self:line(st)
    local v = self:capture(st.body)
    self:emit(
      ("o[#o + 1] = rt.out(env, rt.markup(env, %s))"):format(
        self:apply_filters(("rt.markup(env, %s)"):format(v), st.filters)
      )
    )
  elseif k == "With" then
    self:line(st)
    self:emit("do")
    self:indent(1)
    -- The values are computed before any of the names is set (Jinja).
    local bindings = {}
    for _, a in ipairs(st.assigns) do
      local vars = {}
      for j, name in ipairs(a.targets) do
        vars[j] = self:tmp()
        bindings[name] = { lua = vars[j], sure = true }
      end
      if #vars == 1 then
        self:emit(("local %s = %s"):format(vars[1], self:expr(a.expr)))
      else
        self:emit(
          ("local %s = rt.unpack(%s, %d)"):format(
            table.concat(vars, ", "),
            self:expr(a.expr),
            #vars
          )
        )
      end
    end
    self:scoped_body(st.body, bindings)
    self:indent(-1)
    self:emit("end")
  elseif k == "Do" then
    self:line(st)
    self:emit(("local _ = %s"):format(self:expr(st.expr)))
  elseif k == "Autoescape" then
    self:line(st)
    local saved = self:tmp()
    self:emit(("local %s = env.autoescape"):format(saved))
    self:emit(("env.autoescape = rt.truthy(%s)"):format(self:expr(st.expr)))
    self:body(st.body)
    self:emit(("env.autoescape = %s"):format(saved))
  elseif k == "Macro" then
    self:line(st)
    local b = self.scopes[#self.scopes][st.name]
    self:macro(b.lua, st.name, st.params, st.body)
    self:export(st.name, b.lua)
  elseif k == "CallBlock" then
    self:line(st)
    local caller = self:tmp()
    self:emit(("local %s"):format(caller))
    self:macro(caller, "caller", st.params, st.body)
    local call = vim.deepcopy(st.call)
    call.kwargs = vim.list_extend(
      vim.deepcopy(call.kwargs or {}),
      { { "caller", { k = "Raw", lua = caller } } }
    )
    self:emit(("o[#o + 1] = rt.out(env, %s)"):format(self:expr(call)))
  elseif k == "Import" then
    self:line(st)
    local b = self.scopes[#self.scopes][st.alias]
    self:emit(
      ("%s = rt.import(env, %s, %s)"):format(b.lua, self:expr(st.target), self:import_context(st))
    )
  elseif k == "FromImport" then
    self:line(st)
    local mod = self:tmp()
    self:emit(
      ("local %s = rt.import(env, %s, %s)"):format(
        mod,
        self:expr(st.target),
        self:import_context(st)
      )
    )
    for _, n in ipairs(st.names) do
      local b = self.scopes[#self.scopes][n.alias]
      self:emit(("%s = rt.import_name(%s, %q)"):format(b.lua, mod, n.name))
    end
  elseif k == "Include" then
    self:line(st)
    self:emit(
      ("o[#o + 1] = rt.include(env, %s, %s, %s)"):format(
        self:expr(st.target),
        tostring(st.ignore_missing),
        self:import_context(st)
      )
    )
  elseif k == "Extends" then
    self:line(st)
    self:emit(("rt.extends(env, reg, %s, #o)"):format(self:expr(st.target)))
  elseif k == "Block" then
    self:line(st)
    local bctx = st.scoped and ("rt.layer(ctx, %s)"):format(self:visible_locals()) or "ctx"
    self:emit(("o[#o + 1] = rt.render_block(env, reg, %q, %s)"):format(st.name, bctx))
  else
    error("unknown statement node " .. tostring(k))
  end
end

function C:if_chain(st, idx)
  local br = st.branches[idx]
  self:emit(("L.l = %d"):format(br.line))
  self:emit(("if rt.truthy(%s) then"):format(self:expr(br.test)))
  self:indent(1)
  self:body(br.body)
  self:indent(-1)
  if idx < #st.branches then
    self:emit("else")
    self:indent(1)
    self:if_chain(st, idx + 1)
    self:indent(-1)
  elseif st.else_ then
    self:emit("else")
    self:indent(1)
    self:body(st.else_)
    self:indent(-1)
  end
  self:emit("end")
end

---Define the functions of the template's blocks (at the top: they see the top-level
---variables) and register them in `reg`.
function C:blocks(body)
  local blocks, seen = {}, {}
  walk(body, function(st)
    if st.k == "Block" then
      if seen[st.name] then
        self:fail(st, "block '%s' defined twice", st.name)
      end
      seen[st.name] = true
      blocks[#blocks + 1] = st
    end
    return st.k ~= "Macro"
  end)
  if #blocks == 0 then
    return
  end
  local fns, required = {}, {}
  for _, b in ipairs(blocks) do
    local fn, sup = self:tmp(), self:tmp()
    self:emit(("local %s = function(ctx, %s)"):format(fn, sup))
    self:indent(1)
    self:emit("local o = {}")
    local loops = self.loops
    self.loops = {}
    self:scoped_body(b.body, { super = { lua = sup, sure = true } })
    self.loops = loops
    self:emit("return table.concat(o)")
    self:indent(-1)
    self:emit("end")
    fns[#fns + 1] = ("[%q] = %s"):format(b.name, fn)
    if b.required then
      required[#required + 1] = ("[%q] = true"):format(b.name)
    end
  end
  self:emit(
    ("rt.add_blocks(reg, { %s }, { %s })"):format(
      table.concat(fns, ", "),
      table.concat(required, ", ")
    )
  )
end

---Compile an AST body into Lua source.
---@param body table[]
---@return string
function M.compile(body)
  check_reserved(body)
  local c = setmetatable(
    { buf = {}, depth = 0, n = 0, scopes = {}, exports = {}, exported = {}, loops = {} },
    C
  )
  c:emit("local rt = ...")
  c:emit("return function(ctx, env, L, reg)")
  c.depth = 1
  c:emit("reg = rt.blocks(reg)")
  c:emit("local o = {}")
  c:open_scope(body)
  c:blocks(body)
  c:body(body)
  -- {% extends %}: the output is the parent's (with this template's blocks), after the
  -- text before the extends tag.
  local extends = false
  walk(body, function(st)
    extends = extends or st.k == "Extends"
  end)
  -- The second return value lists the top-level variables and macros, for {% import %}.
  local ex = {}
  for _, e in ipairs(c.exports) do
    ex[#ex + 1] = ("{ %q, %s }"):format(e[1], e[2])
  end
  local exports = "{ " .. table.concat(ex, ", ") .. " }"
  if extends then
    c:emit(
      ("if reg.parent then return rt.render_parent(env, reg, ctx, %s, o), %s end"):format(
        c:visible_locals(),
        exports
      )
    )
  end
  c:close_scope()
  c:emit("return table.concat(o), " .. exports)
  c.depth = 0
  c:emit("end")
  return table.concat(c.buf, "\n")
end

return M
