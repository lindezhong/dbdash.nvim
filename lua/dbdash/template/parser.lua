-- Template parser: token stream -> AST, following Jinja's grammar and operator precedence.
--
-- Statements: If{branches, else_}, For{targets, iter, test, recursive, body, else_},
--             Set{targets, expr}, SetBlock{targets, filters, body}, SetArg, SetAttr{obj,
--             attr, expr}, With{assigns,
--             body}, Do{expr}, Break, Continue, FilterBlock{filters, body}, Macro,
--             CallBlock{params, call, body}, Import, FromImport, Include{target,
--             ignore_missing, with_context}, Extends{target}, Block{name, scoped,
--             required, body}, Autoescape{expr, body}, Lua, Data{v}, Output{expr}
-- Expressions: Const, Name, List, Dict, Getattr, Getitem, Slice{obj, start, stop, step},
--              Call, Filter, Test, Neg, Pos, Bin{op}, Compare{first, ops}, And, Or, Not,
--              Cond
local errors = require("dbdash.template.errors")

local M = {}

local CMP = { ["=="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }

local DESCRIBE = {
  var_end = "end of print statement",
  block_end = "end of statement block",
  eof = "end of template",
  var_begin = "begin of print statement",
  block_begin = "begin of statement block",
}

local P = {}
P.__index = P

function P:peek(k)
  return self.toks[self.i + (k or 0)]
end

function P:next()
  local t = self.toks[self.i]
  self.i = self.i + 1
  return t
end

function P:fail(tok, msg, ...)
  errors.syntax(tok.line, tok.col, msg, ...)
end

local function describe(tok)
  if DESCRIBE[tok.t] then
    return DESCRIBE[tok.t]
  elseif tok.t == "string" then
    return "string"
  end
  return tostring(tok.v)
end

function P:is_op(v, k)
  local t = self:peek(k)
  return t.t == "op" and t.v == v
end

function P:is_name(v, k)
  local t = self:peek(k)
  return t.t == "name" and t.v == v
end

function P:skip_op(v)
  if self:is_op(v) then
    self:next()
    return true
  end
  return false
end

function P:expect_op(v)
  if not self:skip_op(v) then
    local t = self:peek()
    self:fail(t, "expected token '%s', got '%s'", v, describe(t))
  end
end

function P:expect_block_end()
  local t = self:peek()
  if t.t ~= "block_end" then
    self:fail(t, "expected token 'end of statement block', got '%s'", describe(t))
  end
  self:next()
end

-- Statements -------------------------------------------------------------------------------

---Parse a template body until one of the `ends` tag names (or EOF when ends is nil).
---Returns the body and the end tag name; the stream is left on that name token.
function P:subparse(ends, ends_desc)
  local body = {}
  while true do
    local t = self:peek()
    if t.t == "data" then
      self:next()
      body[#body + 1] = { k = "Data", v = t.v }
    elseif t.t == "var_begin" then
      self:next()
      local e = self:tuple_expression()
      local te = self:peek()
      if te.t ~= "var_end" then
        self:fail(te, "expected token 'end of print statement', got '%s'", describe(te))
      end
      self:next()
      body[#body + 1] = { k = "Output", expr = e, line = t.line }
    elseif t.t == "lua" then
      self:next()
      body[#body + 1] = { k = "Lua", code = t.v, line = t.line }
    elseif t.t == "block_begin" then
      local nt = self:peek(1)
      if nt.t ~= "name" then
        self:fail(nt, "tag name expected")
      end
      if ends and ends[nt.v] then
        self:next()
        return body, nt.v
      end
      self:next()
      body[#body + 1] = self:statement()
    elseif t.t == "eof" then
      if ends then
        self:fail(
          t,
          "Unexpected end of template. Jinja was looking for the following tags: %s.",
          ends_desc
        )
      end
      return body
    else
      self:fail(t, "unexpected '%s'", describe(t))
    end
  end
end

function P:statement()
  local tok = self:next()
  local n = tok.v
  if n == "if" then
    return self:parse_if(tok)
  elseif n == "for" then
    return self:parse_for(tok)
  elseif n == "set" then
    return self:parse_set(tok)
  elseif n == "macro" then
    return self:parse_macro(tok)
  elseif n == "import" then
    return self:parse_import(tok)
  elseif n == "from" then
    return self:parse_from(tok)
  elseif n == "with" then
    return self:parse_with(tok)
  elseif n == "do" then
    local e = self:tuple_expression()
    self:expect_block_end()
    return { k = "Do", expr = e, line = tok.line }
  elseif n == "break" or n == "continue" then
    self:expect_block_end()
    return { k = n == "break" and "Break" or "Continue", line = tok.line, col = tok.col }
  elseif n == "filter" then
    local filters = self:filter_chain()
    self:expect_block_end()
    local body = self:end_block("endfilter")
    return { k = "FilterBlock", filters = filters, body = body, line = tok.line }
  elseif n == "call" then
    return self:parse_call_block(tok)
  elseif n == "include" then
    return self:parse_include(tok)
  elseif n == "extends" then
    local target = self:expression()
    self:expect_block_end()
    return { k = "Extends", target = target, line = tok.line }
  elseif n == "block" then
    return self:parse_block(tok)
  elseif n == "autoescape" then
    local e = self:expression()
    self:expect_block_end()
    local body = self:end_block("endautoescape")
    return { k = "Autoescape", expr = e, body = body, line = tok.line }
  end
  self:fail(tok, "Encountered unknown tag '%s'.", n)
end

---The body up to {% <tag> %}, consuming the end tag.
function P:end_block(tag)
  local body = self:subparse({ [tag] = true }, "'" .. tag .. "'")
  self:next()
  self:expect_block_end()
  return body
end

---Filters of {% filter %} and {% set x | f %}: name(args) | name ...
function P:filter_chain()
  local out = {}
  repeat
    local t = self:next()
    if t.t ~= "name" then
      self:fail(t, "expected filter name, got '%s'", describe(t))
    end
    local f = { name = t.v, args = {}, kwargs = {}, line = t.line, col = t.col }
    if self:is_op("(") then
      self:next()
      f.args, f.kwargs, f.dyn_args, f.dyn_kwargs = self:p_args()
    end
    out[#out + 1] = f
  until not self:skip_op("|")
  return out
end

---{% with a = 1, b = 2 %} ... {% endwith %}
function P:parse_with(tok)
  local assigns = {}
  while self:peek().t ~= "block_end" do
    if #assigns > 0 then
      self:expect_op(",")
    end
    local targets = self:targets()
    self:expect_op("=")
    assigns[#assigns + 1] = { targets = targets, expr = self:expression() }
  end
  self:expect_block_end()
  local body = self:end_block("endwith")
  return { k = "With", assigns = assigns, body = body, line = tok.line }
end

---{% call(params) macro(args) %} ... {% endcall %}
function P:parse_call_block(tok)
  local params = {}
  if self:is_op("(") then
    self:next()
    params = self:macro_params()
  end
  local call = self:expression()
  if call.k ~= "Call" then
    self:fail(tok, "expected call")
  end
  self:expect_block_end()
  local body = self:end_block("endcall")
  return { k = "CallBlock", params = params, call = call, body = body, line = tok.line }
end

---{% include 'file' [ignore missing] [with context | without context] %}
function P:parse_include(tok)
  local target = self:expression()
  local ignore = false
  if self:is_name("ignore") and self:is_name("missing", 1) then
    self:next()
    self:next()
    ignore = true
  end
  local with_context = self:context_clause(true)
  self:expect_block_end()
  return { k = "Include", target = target, ignore_missing = ignore, with_context = with_context, line = tok.line }
end

---{% block name [scoped] [required] %} ... {% endblock [name] %}
function P:parse_block(tok)
  local nt = self:next()
  if nt.t ~= "name" then
    self:fail(nt, "expected block name")
  end
  local scoped, required = false, false
  if self:is_name("scoped") then
    self:next()
    scoped = true
  end
  if self:is_name("required") then
    self:next()
    required = true
  end
  self:expect_block_end()
  local body = self:subparse({ endblock = true }, "'endblock'")
  self:next()
  if self:peek().t == "name" then
    local en = self:next()
    if en.v ~= nt.v then
      self:fail(en, "mismatching name of block: '%s' closed with '%s'", nt.v, en.v)
    end
  end
  self:expect_block_end()
  if required then
    for _, st in ipairs(body) do
      if not (st.k == "Data" and st.v:match("^%s*$")) then
        self:fail(tok, "Required blocks can only contain comments or whitespace")
      end
    end
  end
  return { k = "Block", name = nt.v, scoped = scoped, required = required, body = body, line = tok.line, col = nt.col }
end

function P:parse_if(tok)
  local node = { k = "If", branches = {}, line = tok.line }
  local test, line = self:expression(), tok.line
  self:expect_block_end()
  while true do
    local body, e = self:subparse(
      { elif = true, ["else"] = true, endif = true },
      "'elif' or 'else' or 'endif'"
    )
    node.branches[#node.branches + 1] = { test = test, body = body, line = line }
    local et = self:next()
    if e == "elif" then
      test, line = self:expression(), et.line
      self:expect_block_end()
    elseif e == "else" then
      self:expect_block_end()
      node.else_ = self:subparse({ endif = true }, "'endif'")
      self:next()
      self:expect_block_end()
      return node
    else
      self:expect_block_end()
      return node
    end
  end
end

---Assignment targets: name, name, ... (optionally parenthesized).
function P:targets()
  local paren = self:skip_op("(")
  local names = {}
  repeat
    local t = self:next()
    if t.t ~= "name" then
      self:fail(t, "expected a variable name, got '%s'", describe(t))
    end
    if self:is_op(".") or self:is_op("[") then
      self:fail(t, "assigning to attributes or items is not supported")
    end
    names[#names + 1] = t.v
  until not self:skip_op(",")
  if paren then
    self:expect_op(")")
  end
  return names
end

function P:parse_for(tok)
  local targets = self:targets()
  if not self:is_name("in") then
    local t = self:peek()
    self:fail(t, "expected token 'in', got '%s'", describe(t))
  end
  self:next()
  local iter = self:tuple_expression(false)
  local test, recursive
  if self:is_name("if") then
    self:next()
    test = self:expression()
  end
  if self:is_name("recursive") then
    self:next()
    recursive = true
  end
  self:expect_block_end()
  local body, e = self:subparse({ endfor = true, ["else"] = true }, "'endfor' or 'else'")
  self:next()
  local else_
  if e == "else" then
    self:expect_block_end()
    else_ = self:subparse({ endfor = true }, "'endfor'")
    self:next()
  end
  self:expect_block_end()
  return { k = "For", targets = targets, iter = iter, test = test, recursive = recursive, body = body, else_ = else_, line = tok.line }
end

function P:parse_set(tok)
  -- {% set ns.attr = expr %}: an attribute of a namespace(); {% set args.name = expr %}
  -- assigns a dashboard argument ({% set meta.x %} cannot).
  local t, dot, attr = self:peek(), self:peek(1), self:peek(2)
  if t.t == "name" and dot.t == "op" and dot.v == "." and attr.t == "name" and self:is_op("=", 3) then
    if t.v == "meta" then
      self:fail(t, "'meta' is read-only (dashboard metadata)")
    end
    self.i = self.i + 4
    local e = self:tuple_expression()
    self:expect_block_end()
    if t.v == "args" then
      return { k = "SetArg", name = attr.v, expr = e, line = tok.line }
    end
    return { k = "SetAttr", obj = { k = "Name", name = t.v, line = t.line, col = t.col }, attr = attr.v, expr = e, line = tok.line }
  end
  local targets = self:targets()
  if not self:skip_op("=") then
    -- {% set x %}...{% endset %} (optionally {% set x | filter %}): the body's output.
    local filters = {}
    if self:skip_op("|") then
      filters = self:filter_chain()
    end
    self:expect_block_end()
    local body = self:end_block("endset")
    return { k = "SetBlock", targets = targets, filters = filters, body = body, line = tok.line }
  end
  local e = self:tuple_expression()
  self:expect_block_end()
  return { k = "Set", targets = targets, expr = e, line = tok.line }
end

---Parameters "a, b=default)" after "(", consuming the ")".
function P:macro_params()
  local params, seen_default = {}, false
  while not self:is_op(")") do
    local pt = self:next()
    if pt.t ~= "name" then
      self:fail(pt, "expected parameter name, got '%s'", describe(pt))
    end
    local default
    if self:skip_op("=") then
      default = self:expression()
      seen_default = true
    elseif seen_default then
      self:fail(pt, "non-default argument follows default argument")
    end
    params[#params + 1] = { name = pt.v, default = default }
    if not self:skip_op(",") then
      break
    end
  end
  self:expect_op(")")
  return params
end

---{% macro name(a, b=default) %}...{% endmacro %}
function P:parse_macro(tok)
  local nt = self:next()
  if nt.t ~= "name" then
    self:fail(nt, "expected macro name")
  end
  self:expect_op("(")
  local params = self:macro_params()
  self:expect_block_end()
  local body = self:subparse({ endmacro = true }, "'endmacro'")
  self:next()
  self:expect_block_end()
  return { k = "Macro", name = nt.v, params = params, body = body, line = tok.line }
end

---"with context" / "without context" after an import or include: true for with.
function P:context_clause(default)
  if (self:is_name("with") or self:is_name("without")) and self:is_name("context", 1) then
    local with = self:next().v == "with"
    self:next()
    return with
  end
  return default
end

---{% import 'file' as name %}
function P:parse_import(tok)
  local target = self:expression()
  if not self:is_name("as") then
    self:fail(self:peek(), "expected 'as' after the import target")
  end
  self:next()
  local alias = self:next()
  if alias.t ~= "name" then
    self:fail(alias, "expected a name after 'as'")
  end
  local with_context = self:context_clause(false)
  self:expect_block_end()
  return { k = "Import", target = target, alias = alias.v, with_context = with_context, line = tok.line }
end

---{% from 'file' import a, b as c %}
function P:parse_from(tok)
  local target = self:expression()
  if not self:is_name("import") then
    self:fail(self:peek(), "expected 'import'")
  end
  self:next()
  local names = {}
  repeat
    if self:is_name("with") or self:is_name("without") then
      break
    end
    local nt = self:next()
    if nt.t ~= "name" then
      self:fail(nt, "expected a name to import")
    end
    local alias = nt.v
    if self:is_name("as") then
      self:next()
      local at = self:next()
      if at.t ~= "name" then
        self:fail(at, "expected a name after 'as'")
      end
      alias = at.v
    end
    names[#names + 1] = { name = nt.v, alias = alias }
  until not self:skip_op(",")
  local with_context = self:context_clause(false)
  self:expect_block_end()
  return { k = "FromImport", target = target, names = names, with_context = with_context, line = tok.line }
end

-- Expressions ------------------------------------------------------------------------------

local function node(k, tok, fields)
  fields.k = k
  fields.line = tok.line
  fields.col = tok.col
  return fields
end

local TUPLE_END = { var_end = true, block_end = true, eof = true }

---An expression, or several separated by commas: a tuple without parentheses
---({{ 1, 2 }}, {% set a, b = 1, 2 %}, {% for x in 1, 2 %}).
---@param with_cond boolean? false disables "a if b else c" (loop iterables)
function P:tuple_expression(with_cond)
  local t = self:peek()
  local e = self:expression(with_cond)
  if not self:is_op(",") then
    return e
  end
  local items = { e }
  while self:skip_op(",") do
    local nt = self:peek()
    if TUPLE_END[nt.t] or (nt.t == "name" and (nt.v == "if" or nt.v == "recursive")) then
      break
    end
    items[#items + 1] = self:expression(with_cond)
  end
  return node("List", t, { items = items, tuple = true })
end

---@param with_cond boolean? false disables "a if b else c" (used for loop iterables)
function P:expression(with_cond)
  if with_cond == false then
    return self:p_or()
  end
  local e = self:p_or()
  while self:is_name("if") do
    local t = self:next()
    local test = self:p_or()
    local else_
    if self:is_name("else") then
      self:next()
      else_ = self:expression()
    end
    e = node("Cond", t, { test = test, a = e, b = else_ })
  end
  return e
end

function P:p_or()
  local l = self:p_and()
  while self:is_name("or") do
    local t = self:next()
    l = node("Or", t, { l = l, r = self:p_and() })
  end
  return l
end

function P:p_and()
  local l = self:p_not()
  while self:is_name("and") do
    local t = self:next()
    l = node("And", t, { l = l, r = self:p_not() })
  end
  return l
end

function P:p_not()
  if self:is_name("not") then
    local t = self:next()
    return node("Not", t, { node = self:p_not() })
  end
  return self:p_compare()
end

function P:p_compare()
  local first = self:p_math1()
  local ops = {}
  while true do
    local t = self:peek()
    local op
    if t.t == "op" and CMP[t.v] then
      op = t.v
      self:next()
    elseif self:is_name("in") then
      op = "in"
      self:next()
    elseif self:is_name("not") and self:is_name("in", 1) then
      op = "notin"
      self:next()
      self:next()
    else
      break
    end
    ops[#ops + 1] = { op = op, expr = self:p_math1(), line = t.line }
  end
  if #ops == 0 then
    return first
  end
  return { k = "Compare", first = first, ops = ops, line = ops[1].line }
end

---Left-associative binary operator level.
local function binary(next_level, ops)
  return function(self)
    local l = self[next_level](self)
    while true do
      local t = self:peek()
      if t.t == "op" and ops[t.v] then
        self:next()
        l = node("Bin", t, { op = t.v, l = l, r = self[next_level](self) })
      else
        return l
      end
    end
  end
end

P.p_pow = binary("p_unary", { ["**"] = true })
P.p_math2 = binary("p_pow", { ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true })
P.p_concat = binary("p_math2", { ["~"] = true })
P.p_math1 = binary("p_concat", { ["+"] = true, ["-"] = true })

function P:p_unary(with_filter)
  local t = self:peek()
  local n
  if self:is_op("-") then
    self:next()
    n = node("Neg", t, { node = self:p_unary(false) })
  elseif self:is_op("+") then
    self:next()
    n = node("Pos", t, { node = self:p_unary(false) })
  else
    n = self:p_primary()
  end
  n = self:p_postfix(n)
  if with_filter ~= false then
    n = self:p_filter_expr(n)
  end
  return n
end

function P:p_primary()
  local t = self:next()
  if t.t == "name" then
    local v = t.v
    if v == "true" or v == "True" then
      return node("Const", t, { v = true })
    elseif v == "false" or v == "False" then
      return node("Const", t, { v = false })
    elseif v == "none" or v == "None" then
      return node("Const", t, { v = vim.NIL })
    end
    return node("Name", t, { name = v })
  elseif t.t == "string" then
    local parts = { t.v }
    while self:peek().t == "string" do
      parts[#parts + 1] = self:next().v
    end
    return node("Const", t, { v = table.concat(parts) })
  elseif t.t == "int" then
    return node("Const", t, { v = t.v })
  elseif t.t == "float" then
    return node("Const", t, { v = t.v, float = true })
  elseif t.t == "op" and t.v == "(" then
    if self:skip_op(")") then
      return node("List", t, { items = {}, tuple = true })
    end
    local e = self:expression()
    if self:is_op(",") then
      local items = { e }
      while self:skip_op(",") do
        if self:is_op(")") then
          break
        end
        items[#items + 1] = self:expression()
      end
      e = node("List", t, { items = items, tuple = true })
    end
    self:expect_op(")")
    return e
  elseif t.t == "op" and t.v == "[" then
    local items = {}
    while not self:is_op("]") do
      items[#items + 1] = self:expression()
      if not self:skip_op(",") then
        break
      end
    end
    self:expect_op("]")
    return node("List", t, { items = items })
  elseif t.t == "op" and t.v == "{" then
    local pairs_ = {}
    while not self:is_op("}") do
      local k = self:expression()
      self:expect_op(":")
      pairs_[#pairs_ + 1] = { k, self:expression() }
      if not self:skip_op(",") then
        break
      end
    end
    self:expect_op("}")
    return node("Dict", t, { pairs = pairs_ })
  end
  self:fail(t, "unexpected '%s'", describe(t))
end

function P:p_postfix(n)
  while true do
    local t = self:peek()
    if self:is_op(".") then
      self:next()
      local a = self:next()
      if a.t == "name" then
        n = node("Getattr", a, { obj = n, name = a.v })
      elseif a.t == "int" then
        n = node("Getitem", a, { obj = n, key = node("Const", a, { v = a.v }) })
      else
        self:fail(a, "expected name or number after '.'")
      end
    elseif self:is_op("[") then
      self:next()
      -- xs[i], or a slice xs[start:stop:step] (each part optional)
      local start, stop, step, slice
      if not self:is_op(":") then
        start = self:expression()
      end
      if self:skip_op(":") then
        slice = true
        if not (self:is_op("]") or self:is_op(":")) then
          stop = self:expression()
        end
        if self:skip_op(":") and not self:is_op("]") then
          step = self:expression()
        end
      end
      self:expect_op("]")
      if slice then
        n = node("Slice", t, { obj = n, start = start, stop = stop, step = step })
      else
        n = node("Getitem", t, { obj = n, key = start })
      end
    elseif self:is_op("(") then
      n = self:p_call(n)
    else
      return n
    end
  end
end

---Parse "(args)" after a callee. Returns a Call node.
function P:p_call(fn)
  local t = self:next() -- "("
  local args, kwargs, dyn_args, dyn_kwargs = self:p_args()
  return node("Call", t, { fn = fn, args = args, kwargs = kwargs, dyn_args = dyn_args, dyn_kwargs = dyn_kwargs })
end

---Parse call arguments after "(" up to and including ")": positional, keyword, then
---*list and **mapping.
function P:p_args()
  local args, kwargs, dyn_args, dyn_kwargs = {}, {}, nil, nil
  while not self:is_op(")") do
    if self:is_op("*") then
      self:next()
      dyn_args = self:expression()
    elseif self:is_op("**") then
      self:next()
      dyn_kwargs = self:expression()
    elseif dyn_args or dyn_kwargs then
      self:fail(self:peek(), "invalid syntax for function call expression")
    elseif self:peek().t == "name" and self:is_op("=", 1) then
      local name = self:next().v
      self:next()
      kwargs[#kwargs + 1] = { name, self:expression() }
    else
      if #kwargs > 0 then
        self:fail(self:peek(), "positional argument follows keyword argument")
      end
      args[#args + 1] = self:expression()
    end
    if not self:skip_op(",") then
      break
    end
  end
  self:expect_op(")")
  return args, kwargs, dyn_args, dyn_kwargs
end

local TEST_ARG_START = { name = true, string = true, int = true, float = true }

function P:p_filter_expr(n)
  while true do
    if self:is_op("|") then
      self:next()
      local t = self:next()
      if t.t ~= "name" then
        self:fail(t, "expected filter name, got '%s'", describe(t))
      end
      local args, kwargs, dyn_args, dyn_kwargs = {}, {}, nil, nil
      if self:is_op("(") then
        self:next()
        args, kwargs, dyn_args, dyn_kwargs = self:p_args()
      end
      n = node("Filter", t, { node = n, name = t.v, args = args, kwargs = kwargs, dyn_args = dyn_args, dyn_kwargs = dyn_kwargs })
    elseif self:is_name("is") then
      self:next()
      local neg = false
      if self:is_name("not") then
        self:next()
        neg = true
      end
      local t = self:next()
      if t.t ~= "name" then
        self:fail(t, "expected test name, got '%s'", describe(t))
      end
      local args, kwargs = {}, {}
      local nx = self:peek()
      if self:is_op("(") then
        self:next()
        args, kwargs = self:p_args()
      elseif
        TEST_ARG_START[nx.t]
        and not (nx.t == "name" and (nx.v == "else" or nx.v == "or" or nx.v == "and" or nx.v == "if"))
      then
        args = { self:p_primary() }
      end
      n = node("Test", t, { node = n, name = t.v, args = args, kwargs = kwargs, neg = neg })
    elseif self:is_op("(") then
      n = self:p_call(n)
    else
      return n
    end
  end
end

---Parse a token list into a template body.
---@param toks dbdash.template.Token[]
---@return table[] body
function M.parse(toks)
  local p = setmetatable({ toks = toks, i = 1 }, P)
  return p:subparse(nil)
end

return M
