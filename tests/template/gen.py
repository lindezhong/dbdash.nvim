"""Generate template test cases with real Jinja2 (dev-only; runtime never needs Python).

Usage: python3 -I tests/template/gen.py  ->  tests/template/cases.json

Each case: {name, template, ctx (JSON text, parsed by the Lua YAML parser to keep key
order), expected | error: {type, line}}. Known, documented deviations of the Lua engine
are given as "lua_expected" (integral floats render without ".0" because Lua numbers do
not distinguish int from float).
"""
import json
import pathlib

import jinja2

env = jinja2.Environment(
    trim_blocks=True,
    lstrip_blocks=True,
    undefined=jinja2.StrictUndefined,
    autoescape=False,
)

CTX = {
    "x": 5,
    "s": "Hello",
    "name": "it's",
    "items": [3, 1, 2],
    "names": ["IT", "HR", "Finance"],
    "d": {"b": 2, "a": 1, "nested": {"k": "v"}},
    "users": [{"name": "ann", "age": 30}, {"name": "bob", "age": 25}],
    "empty_list": [],
    "empty_map": {},
    "zero": 0,
    "blank": "",
    "nothing": None,
    "flag": True,
    "off": False,
    "pi": 3.14159,
}

# (name, template, ctx_override or None, lua_expected or None)
CASES = [
    # --- whitespace control -------------------------------------------------------------
    ("text only", "SELECT 1", None, None),
    ("variable", "a {{ x }} b", None, None),
    ("trailing newline dropped", "x\n", None, None),
    ("only one trailing newline dropped", "x\n\n", None, None),
    ("trim_blocks", "{% if true %}\nyes\n{% endif %}\nend", None, None),
    ("lstrip_blocks", "  {% if true %}\n  x\n  {% endif %}\ny", None, None),
    ("lstrip not for variables", "  {{ x }}\n", None, None),
    ("lstrip only at line start", "a {% if true %}b{% endif %} c", None, None),
    ("minus strips both sides", "a  \n {%- if true -%} \n b \n {%- endif -%}  c", None, None),
    ("minus on variable", "a   {{- x -}}   b", None, None),
    ("plus disables lstrip", "  {%+ if true %}x{% endif %}", None, None),
    ("comment inline", "a {# note #} b", None, None),
    ("comment trims newline", "{# note #}\nx", None, None),
    ("comment lstrip", "  {# note #}\nx", None, None),
    ("multiline comment", "a{# line1\nline2 #}b", None, None),
    ("raw block", "{% raw %}{{ x }}{% if %}{% endraw %}", None, None),
    ("raw with trim", "{% raw %}\n{{ x }}\n{% endraw %}\nz", None, None),
    ("delimiters inside strings", "{{ '}}' ~ \"%}\" }}", None, None),
    ("dict literal braces", "{{ {'a': {'b': 1}}['a']['b'] }}", None, None),
    # --- literals -----------------------------------------------------------------------
    ("int literal", "{{ 42 }}", None, None),
    ("float literal", "{{ 1.5 }} {{ 0.1 }} {{ 1e-05 }} {{ 1_000 }}", None, None),
    ("integral float literal", "{{ 2.0 }}", None, "2"),
    ("string escapes", "{{ 'a\\tb' }}|{{ \"it's\" }}|{{ 'x\\'y' }}", None, None),
    ("adjacent strings", "{{ 'a' 'b' \"c\" }}", None, None),
    ("constants", "{{ true }} {{ True }} {{ false }} {{ none }} {{ None }}", None, None),
    ("list literal repr", "{{ [1, 'a', none, true, [2]] }}", None, None),
    ("dict literal repr", "{{ {'k': 'v', 'n': 1} }}", None, None),
    ("string repr quotes", "{{ [\"it's\", 'say \"hi\"', 'a\\nb'] }}", None, None),
    ("tuple literal", "{% for a, b in [(1, 2), (3, 4)] %}{{ a }}{{ b }};{% endfor %}", None, None),
    # --- arithmetic -----------------------------------------------------------------------
    ("precedence", "{{ 1 + 2 * 3 }} {{ (1 + 2) * 3 }} {{ 2 * 3 % 4 }}", None, None),
    ("power left assoc", "{{ 2 ** 3 ** 2 }}", None, None),
    ("floor div and mod", "{{ 7 // 2 }} {{ -7 // 2 }} {{ 7 % 3 }} {{ -7 % 3 }} {{ 7 % -3 }}", None, None),
    ("true division", "{{ 1 / 4 }} {{ 7 / 2 }}", None, None),
    ("true division integral", "{{ 4 / 2 }}", None, "2"),
    ("unary", "{{ -x }} {{ +x }} {{ - -x }} {{ -1|abs }}", None, None),
    ("string plus", "{{ 'a' + 'b' }} {{ s + '!' }}", None, None),
    ("list plus", "{{ [1] + [2, 3] }}", None, None),
    ("string times", "{{ 'ab' * 3 }} {{ [0] * 2 }}", None, None),
    ("tilde concat", "{{ 'a' ~ 1 ~ none ~ true ~ 1.5 }}", None, None),
    ("float math", "{{ pi * 2 }} {{ 0.1 + 0.2 }}", None, None),
    # --- comparison and logic ------------------------------------------------------------
    ("comparisons", "{{ 1 < 2 }} {{ 2 <= 1 }} {{ 'a' == 'a' }} {{ 'a' != 'b' }} {{ 'b' > 'a' }}", None, None),
    ("chained comparison", "{{ 1 < x < 10 }} {{ 1 < x > 10 }}", None, None),
    ("deep equality", "{{ [1, [2]] == [1, [2]] }} {{ {'a': 1} == {'a': 1} }} {{ 1 == 1.0 }}", None, None),
    ("in operator", "{{ 1 in items }} {{ 9 in items }} {{ 'ell' in s }} {{ 'a' in d }} {{ 'z' not in d }}", None, None),
    ("and or return operands", "{{ 0 or 'x' }}|{{ '' and 1 }}|{{ 1 and 2 }}|{{ none or [] }}|{{ zero or blank }}", None, None),
    ("not", "{{ not 0 }} {{ not 'a' }} {{ not empty_list }} {{ not not flag }}", None, None),
    ("not in precedence", "{{ not 1 in [2] }} {{ not x == 5 }}", None, None),
    ("conditional expression", "{{ 'y' if flag else 'n' }} {{ 'y' if off else 'n' }} {{ 1 if 0 else 2 if 1 else 3 }}", None, None),
    # --- truthiness -------------------------------------------------------------------
    ("python truthiness", "{% for v in [0, '', [], {}, none, false, 0.0, 'a', [0], {'k': 0}, -1] %}{{ 'T' if v else 'F' }}{% endfor %}", None, None),
    ("if on context values", "{% if zero %}a{% elif blank %}b{% elif empty_map %}c{% elif nothing %}d{% else %}e{% endif %}", None, None),
    # --- access -----------------------------------------------------------------------
    ("attribute and item", "{{ d.a }} {{ d['b'] }} {{ d.nested.k }} {{ d['nested']['k'] }}", None, None),
    ("list index", "{{ items[0] }} {{ items[-1] }} {{ users[1].name }} {{ users[0]['age'] }}", None, None),
    ("string index", "{{ s[0] }}{{ s[-1] }}", None, None),
    ("numeric attribute", "{{ items.0 }}", None, None),
    ("unicode string index", "{{ '中文字'[1] }} {{ '中文字'|length }}", None, None),
    # --- methods ------------------------------------------------------------------------
    ("dict items keys values", "{% for k, v in d.items() %}{{ k }}={{ v }};{% endfor %}|{% for k in d.keys() %}{{ k }}{% endfor %}|{% for v in d.values() %}{{ v }}{% endfor %}", None, None),
    ("dict get", "{{ d.get('a') }} {{ d.get('zz') }} {{ d.get('zz', 'dflt') }}", None, None),
    ("string methods", "{{ s.upper() }} {{ s.lower() }} [{{ '  pad  '.strip() }}] {{ s.startswith('He') }} {{ s.endswith('x') }}", None, None),
    # --- tests --------------------------------------------------------------------------
    ("is defined", "{{ x is defined }} {{ zz is defined }} {{ zz is not defined }} {{ zz is undefined }} {{ d.zz is defined }}", None, None),
    ("is none", "{{ nothing is none }} {{ 0 is none }} {{ nothing is not none }}", None, None),
    ("type tests", "{{ 1 is number }} {{ 1.5 is number }} {{ true is number }} {{ '1' is number }} {{ s is string }} {{ 1 is string }}", None, None),
    ("collection tests", "{{ d is mapping }} {{ items is mapping }} {{ items is sequence }} {{ s is sequence }} {{ d is sequence }} {{ 1 is sequence }}", None, None),
    ("true false tests", "{{ true is true }} {{ 1 is true }} {{ false is false }} {{ 0 is false }}", None, None),
    # --- filters ------------------------------------------------------------------------
    ("default", "{{ zz|default('dflt') }} {{ nothing|default('dflt') }} {{ blank|default('dflt', true) }} {{ x|d(0) }} {{ zz|default }}|", None, None),
    ("default on missing attribute", "{{ d.zz|default('none here') }}", None, None),
    ("length count", "{{ s|length }} {{ items|count }} {{ d|length }} {{ empty_list|length }}", None, None),
    ("upper lower trim", "{{ 'aBc'|upper }} {{ 'aBc'|lower }} [{{ '  t  '|trim }}] [{{ 'xxaxx'|trim('x') }}]", None, None),
    ("replace", "{{ 'a-b-c'|replace('-', '+') }} {{ 'a-b-c'|replace('-', '', 1) }}", None, None),
    ("join", "{{ names|join(', ') }} {{ items|join }} {{ users|join('/', attribute='name') }}", None, None),
    ("first last", "{{ items|first }} {{ items|last }} {{ s|first }} {{ s|last }}", None, None),
    ("int filter", "{{ '3'|int }} {{ '3.7'|int }} {{ 'x'|int }} {{ 'x'|int(5) }} {{ 'ff'|int(base=16) }} {{ 3.9|int }} {{ -3.9|int }}", None, None),
    ("float filter", "{{ '1.5'|float }} {{ 'x'|float(2.5) }}", None, None),
    ("float filter integral", "{{ '3'|float }}", None, "3"),
    ("string filter", "{{ 1|string ~ 'x' }} {{ none|string }} {{ [1]|string }}", None, None),
    ("abs", "{{ -3|abs }} {{ (-2.5)|abs }}", None, None),
    ("round", "{{ 2.567|round(2) }} {{ 2.561|round(2, 'floor') }} {{ 2.561|round(1, 'ceil') }}", None, None),
    ("round integral", "{{ 2.5|round }} {{ 3.5|round }} {{ 2.1|round(method='ceil') }}", None, "2 4 3"),
    ("tojson", "{{ d|tojson }}", None, None),
    ("tojson escapes", "{{ {'k': \"<a & b> it's é\", 'l': [1, none, true]}|tojson }}", None, None),
    ("tojson scalars", "{{ 'x'|tojson }} {{ 1|tojson }} {{ none|tojson }} {{ empty_map|tojson }} {{ empty_list|tojson }}", None, None),
    ("safe", "{{ 'a < b'|safe }}", None, None),
    ("filter chain and args", "{{ '  a,b  '|trim|replace(',', ';')|upper }}", None, None),
    ("filter binds tighter than unary", "{{ -1|abs }} {{ - 1|abs }}", None, None),
    ("filter on parenthesized", "{{ (1 - 3)|abs }}", None, None),
    # --- for loops ----------------------------------------------------------------------
    ("loop variables", "{% for i in items %}{{ loop.index }}/{{ loop.index0 }}/{{ loop.revindex }}/{{ loop.revindex0 }}/{{ loop.first }}/{{ loop.last }}/{{ loop.length }};{% endfor %}", None, None),
    ("for else", "{% for i in empty_list %}x{% else %}empty{% endfor %}", None, None),
    ("for over dict iterates keys", "{% for k in d %}{{ k }},{% endfor %}", None, None),
    ("for over string", "{% for c in 'abc' %}{{ c }}-{% endfor %}", None, None),
    ("nested loops", "{% for u in users %}{% for k, v in u.items() %}{{ k }}:{{ v }} {% endfor %}{{ loop.index }}|{% endfor %}", None, None),
    ("range", "{% for i in range(3) %}{{ i }}{% endfor %} {% for i in range(1, 7, 2) %}{{ i }}{% endfor %} {% for i in range(3, 0, -1) %}{{ i }}{% endfor %}", None, None),
    ("loop with sql shape", "SELECT *\nFROM t\nWHERE 1=1\n{% for n in names %}\n  {% if not loop.first %}OR{% else %}AND ({% endif %} dept = '{{ n }}'\n{% endfor %}\n)\n", None, None),
    # --- set ----------------------------------------------------------------------------
    ("set", "{% set y = x * 2 %}{{ y }}", None, None),
    ("set in if is visible after", "{% if true %}{% set y = 1 %}{% endif %}{{ y }}", None, None),
    ("unexecuted set falls back to context", "{% if false %}{% set x = 1 %}{% endif %}{{ x }}", None, None),
    ("set in loop does not leak", "{% set c = 0 %}{% for i in items %}{% set c = c + i %}{% endfor %}{{ c }}", None, None),
    ("loop sees outer set", "{% set p = '>' %}{% for i in items %}{{ p }}{{ i }}{% endfor %}", None, None),
    ("set shadows context", "{% set x = 'local' %}{{ x }}", None, None),
    ("set multiple targets", "{% set a, b = [1, 2] %}{{ a }}{{ b }}", None, None),
    # --- realistic templates (from the legacy examples) --------------------------------
    ("legacy table example", "SELECT \n  datetime('now') as current_time,\n  \"{{key1}}\" as k1,\n  \"{{key2}}\" as k2\n", {"key1": "value1", "key2": "value2"}, None),
    ("conditional where", "SELECT * FROM users\nWHERE age >= {{ min_age }}\n{% if departments %}\n  AND department IN ({% for d in departments %}'{{ d }}'{{ ', ' if not loop.last }}{% endfor %})\n{% endif %}\nORDER BY age", {"min_age": 18, "departments": ["IT", "HR"]}, None),
    ("map argument", "{% for k, v in filters.items() %}AND {{ k }} = '{{ v }}'\n{% endfor %}", {"filters": {"region": "Asia", "level": "senior"}}, None),
    # --- extra whitespace and expression edge cases -------------------------------------
    ("spaces after block tag survive trim", "{% if true %}  \nx{% endif %}", None, None),
    ("minus at line start", "a\n  {%- if true %}\nb\n{% endif %}", None, None),
    ("nested blocks with lstrip", "{% for i in items %}\n  {% if i > 1 %}\n    v{{ i }}\n  {% endif %}\n{% endfor %}\n", None, None),
    ("tests combined with logic", "{{ x is defined and x > 1 }} {{ nothing is not none or 'fallback' }}", None, None),
    ("string comparison", "{{ 'abc' < 'abd' }} {{ '10' < '9' }}", None, None),
    ("big float literal", "{{ 1e20 }} {{ 1.5e300 }} {{ 123456.789 }}", None, None),
    ("small floats", "{{ 0.0001 }} {{ 0.00001234 }}", None, None),
    ("percent literal in string", "{{ '%.2f' }} {{ 'a % b' }}", None, None),
    ("subscript with expression", "{{ users[x - 4].name }} {{ d['ne' ~ 'sted'].k }}", None, None),
    ("default with boolean kwarg", "{{ zero|default('z', boolean=true) }}", None, None),
    ("join on mapping keys", "{{ d|join('|') }}", None, None),
    ("unicode upper", "{{ 'straße é'|upper }} {{ 'straße'.upper() }}", None, None),
    # --- errors -------------------------------------------------------------------------
    ("undefined variable", "a\n\n{{ missing }}", None, None),
    ("undefined attribute", "{{ d.missing }}", None, None),
    ("undefined in condition", "x\n{% if missing %}y{% endif %}", None, None),
    ("undefined in arithmetic", "{{ missing + 1 }}", None, None),
    ("undefined iteration", "{% for i in missing %}{% endfor %}", None, None),
    ("type error plus", "{{ 1 + 'a' }}", None, None),
    ("type error compare", "{{ 'a' < 1 }}", None, None),
    ("division by zero", "{{ 1 / 0 }}", None, None),
    ("syntax unclosed if", "{% if true %}\nx", None, None),
    ("syntax unknown tag", "a\n{% frobnicate %}", None, None),
    ("syntax unknown filter", "{{ x|nope }}", None, None),
    ("syntax bad expression", "{{ 1 + }}", None, None),
    ("syntax unclosed variable", "{{ x ", None, None),
    ("syntax stray endfor", "{% endfor %}", None, None),
    ("syntax else without if", "{% else %}", None, None),
]


# Templates using {% macro %} / {% import %}: (name, template, files, lua_expected).
MACRO_CASES = [
    ("macro basic", "{% macro col(name, alias='') %}{{ name }}{{ ' AS ' ~ alias if alias }}{% endmacro %}SELECT {{ col('a') }}, {{ col('b', 'bee') }}, {{ col(name='c', alias='cee') }}", {}, None),
    ("macro with loop and caller context", "{% macro inlist(field, values) %}{{ field }} IN ({% for v in values %}'{{ v }}'{{ ', ' if not loop.last }}{% endfor %}){% endmacro %}WHERE {{ inlist('dept', names) }}", {}, None),
    ("macro defaults use expressions", "{% macro lim(n=10 * 2) %}LIMIT {{ n }}{% endmacro %}{{ lim() }} {{ lim(5) }}", {}, None),
    ("macro sees template variables", "{% macro show() %}x={{ x }}{% endmacro %}{{ show() }}", {}, None),
    ("macro recursion-free nesting", "{% macro a() %}A{% endmacro %}{% macro b() %}[{{ a() }}]{% endmacro %}{{ b() }}", {}, None),
    ("macro whitespace", "{% macro m() %}\n  inner\n{% endmacro %}\nstart{{ m() }}end", {}, None),
    ("endmacro with name", "{% macro m() %}ok{% endmacro m %}{{ m() }}", {}, None),
    ("import as", "{% import 'helpers.sql' as h %}SELECT {{ h.quote('x') }} FROM {{ h.table }}", {"helpers.sql": "{% macro quote(v) %}'{{ v }}'{% endmacro %}{% macro table() %}t{% endmacro %}"}, None),
    ("from import with alias", "{% from 'helpers.sql' import quote, upper_col as uc %}{{ quote('a') }} {{ uc('b') }}", {"helpers.sql": "{% macro quote(v) %}'{{ v }}'{% endmacro %}{% macro upper_col(c) %}UPPER({{ c }}){% endmacro %}"}, None),
    ("imported template has no caller context", "{% import 'h.sql' as h %}{{ h.m() }}", {"h.sql": "{% macro m() %}{{ x is defined }}{% endmacro %}"}, None),
    ("imported top-level output is discarded", "{% import 'h.sql' as h %}[{{ h.m() }}]", {"h.sql": "IGNORED TEXT {% macro m() %}m{% endmacro %}"}, None),
    ("nested imports", "{% from 'a.sql' import outer %}{{ outer() }}", {"a.sql": "{% import 'b.sql' as b %}{% macro outer() %}<{{ b.inner() }}>{% endmacro %}", "b.sql": "{% macro inner() %}in{% endmacro %}"}, None),
    ("macro too many arguments", "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}", {}, None),
    ("macro unknown keyword", "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(b=1) }}", {}, None),
    ("macro missing argument", "{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}", {}, None),
    ("import missing name", "{% from 'h.sql' import nope %}", {"h.sql": "{% macro m() %}{% endmacro %}"}, None),
]


def error_line(e):
    if isinstance(e, jinja2.TemplateSyntaxError):
        return e.lineno
    tb, line = e.__traceback__, None
    while tb:
        if tb.tb_frame.f_code.co_filename == "<template>":
            line = tb.tb_lineno
        tb = tb.tb_next
    return line


def error_type(e):
    if isinstance(e, jinja2.TemplateSyntaxError):
        return "syntax"
    if isinstance(e, jinja2.UndefinedError):
        return "undefined"
    if isinstance(e, (TypeError, ZeroDivisionError, ValueError)):
        return "type" if isinstance(e, TypeError) else "value"
    return "error"


def main():
    out = []
    for name, tpl, ctx, lua_expected in CASES:
        ctx = ctx if ctx is not None else CTX
        case = {"name": name, "template": tpl, "ctx": json.dumps(ctx, ensure_ascii=False)}
        try:
            case["expected"] = env.from_string(tpl).render(**ctx)
        except Exception as e:  # noqa: BLE001 - every failure kind is recorded
            case["error"] = {"type": error_type(e), "line": error_line(e), "message": str(e)}
        if lua_expected is not None:
            case["lua_expected"] = lua_expected
        out.append(case)
    for name, tpl, files, lua_expected in MACRO_CASES:
        menv = jinja2.Environment(
            trim_blocks=True,
            lstrip_blocks=True,
            undefined=jinja2.StrictUndefined,
            autoescape=False,
            loader=jinja2.DictLoader(files),
        )
        case = {"name": name, "template": tpl, "ctx": json.dumps(CTX, ensure_ascii=False), "files": files}
        try:
            case["expected"] = menv.from_string(tpl).render(**CTX)
        except Exception as e:  # noqa: BLE001
            case["error"] = {"type": error_type(e), "line": error_line(e), "message": str(e)}
        if lua_expected is not None:
            case["lua_expected"] = lua_expected
        out.append(case)
    path = pathlib.Path(__file__).parent / "cases.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {len(out)} cases to {path.name}")


main()
