-- Template parser: token stream -> AST, following Jinja's grammar and operator precedence.
--
-- Statements: If{branches, else_}, For{targets, iter, body, else_}, Set{targets, expr},
--             Data{v}, Output{expr}
-- Expressions: Const, Name, List, Dict, Getattr, Getitem, Call, Filter, Test, Neg, Pos,
--              Bin{op}, Compare{first, ops}, And, Or, Not, Cond
local errors = require("dbdash.template.errors")

local M = {}

local UNSUPPORTED = {
  extends = true,
  block = true,
  include = true,
  call = true,
  filter = true,
  with = true,
  autoescape = true,
  ["break"] = true,
  continue = true,
  ["do"] = true,
  endset = true,
}

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
      local e = self:expression()
      local te = self:peek()
      if te.t ~= "var_end" then
        self:fail(te, "expected token 'end of print statement', got '%s'", describe(te))
      end
      self:next()
      body[#body + 1] = { k = "Output", expr = e, line = t.line }
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
  elseif UNSUPPORTED[n] then
    self:fail(tok, "'%s' is not supported in dbdash templates", n)
  end
  self:fail(tok, "Encountered unknown tag '%s'.", n)
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
  local iter = self:expression(false)
  if self:is_name("if") then
    self:fail(self:peek(), "loop filtering ('for ... if ...') is not supported")
  elseif self:is_name("recursive") then
    self:fail(self:peek(), "recursive loops are not supported")
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
  return { k = "For", targets = targets, iter = iter, body = body, else_ = else_, line = tok.line }
end

function P:parse_set(tok)
  local targets = self:targets()
  if not self:skip_op("=") then
    self:fail(tok, "block set ({%% set x %%}...{%% endset %%}) is not supported")
  end
  local e = self:expression()
  self:expect_block_end()
  return { k = "Set", targets = targets, expr = e, line = tok.line }
end

---{% macro name(a, b=default) %}...{% endmacro %}
function P:parse_macro(tok)
  local nt = self:next()
  if nt.t ~= "name" then
    self:fail(nt, "expected macro name")
  end
  self:expect_op("(")
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
  self:expect_block_end()
  local body = self:subparse({ endmacro = true }, "'endmacro'")
  self:next()
  self:expect_block_end()
  return { k = "Macro", name = nt.v, params = params, body = body, line = tok.line }
end

local function skip_context_clause(self)
  if (self:is_name("with") or self:is_name("without")) and self:is_name("context", 1) then
    local t = self:peek()
    if t.v == "with" then
      self:fail(t, "importing 'with context' is not supported")
    end
    self:next()
    self:next()
  end
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
  skip_context_clause(self)
  self:expect_block_end()
  return { k = "Import", target = target, alias = alias.v, line = tok.line }
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
  skip_context_clause(self)
  self:expect_block_end()
  return { k = "FromImport", target = target, names = names, line = tok.line }
end

-- Expressions ------------------------------------------------------------------------------

local function node(k, tok, fields)
  fields.k = k
  fields.line = tok.line
  fields.col = tok.col
  return fields
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
  elseif t.t == "int" or t.t == "float" then
    return node("Const", t, { v = t.v })
  elseif t.t == "op" and t.v == "(" then
    if self:skip_op(")") then
      return node("List", t, { items = {} })
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
      e = node("List", t, { items = items })
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
      if self:is_op(":") then
        self:fail(self:peek(), "slices are not supported")
      end
      local key = self:expression()
      if self:is_op(":") then
        self:fail(self:peek(), "slices are not supported")
      end
      self:expect_op("]")
      n = node("Getitem", t, { obj = n, key = key })
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
  local args, kwargs = self:p_args()
  return node("Call", t, { fn = fn, args = args, kwargs = kwargs })
end

---Parse call arguments after "(" up to and including ")".
function P:p_args()
  local args, kwargs = {}, {}
  while not self:is_op(")") do
    if self:is_op("*") or self:is_op("**") then
      self:fail(self:peek(), "*args and **kwargs are not supported")
    end
    if self:peek().t == "name" and self:is_op("=", 1) then
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
  return args, kwargs
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
      local args, kwargs = {}, {}
      if self:is_op("(") then
        self:next()
        args, kwargs = self:p_args()
      end
      n = node("Filter", t, { node = n, name = t.v, args = args, kwargs = kwargs })
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
      local args = {}
      local nx = self:peek()
      if self:is_op("(") then
        self:next()
        args = self:p_args()
      elseif
        TEST_ARG_START[nx.t]
        and not (nx.t == "name" and (nx.v == "else" or nx.v == "or" or nx.v == "and" or nx.v == "if"))
      then
        args = { self:p_primary() }
      end
      n = node("Test", t, { node = n, name = t.v, args = args, neg = neg })
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
