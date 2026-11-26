"""Generate template test cases with real Jinja2 (dev-only; runtime never needs Python).

Usage: python3 -I tests/template/gen.py  ->  tests/template/cases.json

Each case: {name, template, ctx (JSON text, parsed by the Lua YAML parser to keep key
order), expected | error: {type, line}}. Known, documented deviations of the Lua engine
would be given as "lua_expected" (there are none at the moment).
"""
import json
import pathlib

import jinja2

# The loopcontrols ({% break %}, {% continue %}) and do ({% do %}) extensions are on: the
# Lua engine has them built in.
EXTENSIONS = ["jinja2.ext.loopcontrols", "jinja2.ext.do"]

env = jinja2.Environment(
    trim_blocks=True,
    lstrip_blocks=True,
    undefined=jinja2.StrictUndefined,
    autoescape=False,
    extensions=EXTENSIONS,
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
    "tree": [{"n": "a", "c": [{"n": "b", "c": []}, {"n": "c", "c": [{"n": "d", "c": []}]}]}],
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
    ("integral float literal", "{{ 2.0 }}", None, None),
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
    ("true division integral", "{{ 4 / 2 }}", None, None),
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
    ("float filter integral", "{{ '3'|float }}", None, None),
    ("string filter", "{{ 1|string ~ 'x' }} {{ none|string }} {{ [1]|string }}", None, None),
    ("abs", "{{ -3|abs }} {{ (-2.5)|abs }}", None, None),
    ("round", "{{ 2.567|round(2) }} {{ 2.561|round(2, 'floor') }} {{ 2.561|round(1, 'ceil') }}", None, None),
    ("round integral", "{{ 2.5|round }} {{ 3.5|round }} {{ 2.1|round(method='ceil') }} {{ 3|round }}", None, None),
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
    # --- realistic templates -----------------------------------------------------------------
    ("table example", "SELECT \n  datetime('now') as current_time,\n  \"{{key1}}\" as k1,\n  \"{{key2}}\" as k2\n", {"key1": "value1", "key2": "value2"}, None),
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
    # --- numbers: int and float ------------------------------------------------------------
    ("float results", "{{ 4 / 2 }} {{ 1e3 }} {{ 2.0 + 1 }} {{ 3 * 1.0 }} {{ 2 ** -1 }} {{ 2 ** 2 }} {{ 7.0 // 2 }} {{ 7.5 % 2 }} {{ 7 % 2.0 }} {{ -2.0 }} {{ 10 / 4 }}", None, None),
    ("float repr", "{{ 1e16 }} {{ 1.0e15 }} {{ [1.0, 2] }} {{ 0.5 * 4 }} {{ -0.0 + 0 }}", None, None),
    ("float compare and truth", "{{ 2 == 2.0 }} {{ 0.0 or 'z' }} {{ 1.0 in [1] }} {{ [2.0][0] }} {{ {'a': 1.0}.a }}", None, None),
    ("float filters", "{{ (2.0)|int }} {{ 2|float }} {{ (2.0)|abs }} {{ -3|abs }} {{ 2.0|string }} {{ 2.0|tojson }} {{ 7|round }} {{ 2.25|round(1) }} {{ 2|round(1, 'floor') }}", None, None),
    ("float type names", "{{ 2.0 is number }} {{ 2.0 is string }}", None, None),
    ("float in string concat", "{{ 'x' ~ 4 / 2 }} {{ 'n=' ~ 1.0 }}", None, None),
    ("float index is an error", "{{ items[1.0] }}", None, None),
    ("range needs ints", "{{ range(2.0) }}", None, None),
    # --- integer literals ----------------------------------------------------------------
    ("hex octal binary literals", "{{ 0x1f }} {{ 0o17 }} {{ 0b101 }} {{ 0x_ff }} {{ 0XAB }} {{ 1_0.5 }}", None, None),
    # --- tuples --------------------------------------------------------------------------
    ("tuple repr", "{{ (1, 2) }} {{ (1,) }} {{ () }} {{ ('a', none, true) }}", None, None),
    ("tuple operations", "{{ (1, 2) + (3,) }} {{ (1, 2) * 2 }} {{ [1] == (1,) }} {{ (1, 2) == (1, 2) }} {{ (1, 2)|tojson }} {{ (1, 2)|length }} {{ 2 in (1, 2) }}", None, None),
    ("tuple plus list is an error", "{{ (1,) + [2] }}", None, None),
    ("implicit tuples", "{% set a, b = 1, 2 %}{{ a }}{{ b }} {% set t = 1, 2 %}{{ t }} {{ 1, 2 }} {% for x in 1, 2 %}{{ x }}{% endfor %}", None, None),
    ("dict views", "{{ d.keys() }} {{ d.values() }} {{ d.items() }} {{ 'a' in d.keys() }} {{ d.items()|length }} {% for k, v in d.items() %}{{ k }}{% endfor %}", None, None),
    # --- str methods ----------------------------------------------------------------------
    ("str split", "{{ 'a,b'.split(',') }} {{ 'a b  c '.split() }} {{ ' a b c'.split(None, 1) }} {{ 'a,b,c'.rsplit(',', 1) }} {{ 'a b c'.rsplit(maxsplit=1) }} {{ 'a,b,c'.split(',', maxsplit=1) }}", None, None),
    ("str join replace find", "{{ '-'.join(['a', 'b']) }} {{ 'abcb'.replace('b', 'x') }} {{ 'abcb'.replace('b', 'x', 1) }} {{ 'abcb'.find('b') }} {{ 'abcb'.rfind('b') }} {{ 'abc'.find('z') }} {{ 'abc'.index('c') }} {{ '中文字'.find('字') }}", None, None),
    ("str case", "{{ 'hello world'.title() }} {{ \"they're bill's\".title() }} {{ 'aBC'.capitalize() }} {{ 'AbC'.swapcase() }} {{ 'ẞ'.casefold() }} {{ 'Hello'.lower() }} {{ 'Hello'.upper() }}", None, None),
    ("str padding", "[{{ 'ab'.center(6, '*') }}] [{{ 'ab'.center(5) }}] [{{ 'abc'.center(6) }}] [{{ 'x'.ljust(3, '.') }}] [{{ 'x'.rjust(3) }}] {{ '5'.zfill(3) }} {{ '-5'.zfill(4) }} [{{ 'a\tb'.expandtabs(4) }}]", None, None),
    ("str tests", "{{ '12'.isdigit() }} {{ 'a1'.isalnum() }} {{ 'ab'.isalpha() }} {{ 'a b'.isalpha() }} {{ ' '.isspace() }} {{ 'Ab Cd'.istitle() }} {{ 'ab'.islower() }} {{ 'AB'.isupper() }} {{ 'a_1'.isidentifier() }} {{ ''.isdigit() }} {{ 'é'.isascii() }}", None, None),
    ("str partition strip affixes", "{{ 'a=b=c'.partition('=') }} {{ 'a=b=c'.rpartition('=') }} {{ 'abc'.partition('x') }} [{{ '  a '.lstrip() }}] [{{ '  a '.rstrip() }}] [{{ 'xxaxx'.strip('x') }}] {{ 'abc'.removeprefix('a') }} {{ 'abc'.removesuffix('c') }} {{ 'abc'.startswith(('x', 'a')) }} {{ 'abc'.endswith('bc') }} {{ 'abc'.startswith('b', 1) }}", None, None),
    ("str count splitlines", "{{ 'abcabc'.count('bc') }} {{ 'abc'.count('') }} {{ 'ab\ncd\r\nef'.splitlines() }} {{ 'ab\ncd'.splitlines(true) }}", None, None),
    ("str.format", "{{ '{} {}'.format(1, 2) }} {{ '{0}{name}{0}'.format('a', name='n') }} {{ '{:>5}|{:<5}|{:^7}|{:.2f}|{:,}|{!r}'.format(1, 2, 3, 3.14159, 1234567, 'q') }}", None, None),
    ("str.format numbers", "{{ '{:08.3f}|{:x}|{:#x}|{:X}|{:b}|{:o}|{:.1%}|{:e}|{:+d}|{:_}|{: d}|{:=+8.2f}'.format(-3.14159, 255, 255, 255, 5, 8, 0.25, 1234.5, 5, 10000, 7, 3.14159) }}", None, None),
    ("str.format general", "{{ '{:g}|{:.3g}|{:.3}|{}|{}|{:.10g}'.format(1234.5, 0.000123456, 3.14159, 2.0, 1e20, 0.1) }}", None, None),
    ("str.format fields", "{{ '{0[1]}|{d[b]}|{1:*^9}|{1:{w}}|'.format(items, 'mid', d=d, w=4) }}{{ '{{}}'.format() }}", None, None),
    ("str.format attribute of a dict", "{{ '{d.a}'.format(d=d) }}", None, None),
    ("str.format errors", "{{ '{} {0}'.format(1) }}", None, None),
    ("str.format missing", "{{ '{} {}'.format(1) }}", None, None),
    ("format_map", "{{ '{a}-{b}'.format_map({'a': 1, 'b': 2}) }}", None, None),
    # --- printf-style formatting -------------------------------------------------------------
    ("percent formatting", "{{ '%s-%d-%.2f-%5s|%-5s|%r %x %o %e %g %%' % ('a', 3, 2.5, 'r', 'l', 'q', 255, 8, 1234.5, 0.0001) }}", None, None),
    ("percent single and mapping", "{{ '%(a)s and %(b)05.1f' % {'a': 1, 'b': 2.25} }} {{ '%s' % 1 }} {{ '%s' % [1, 2] }} {{ '%d%%' % 50 }} {{ '%5.1f|%-6d|%+d|%#x|%#o|%c|%c' % (3.14159, 42, 5, 255, 8, 65, 'z') }}", None, None),
    ("percent with star", "{{ '%*d|%.*f|%3s' % (5, 42, 2, 3.14159, 'ab') }} {{ '%i %u' % (3.9, -2.5) }}", None, None),
    ("percent too few", "{{ '%s %s' % ('a',) }}", None, None),
    ("percent too many", "{{ '%s' % ('a', 'b') }}", None, None),
    ("percent bad number", "{{ '%d' % 'x' }}", None, None),
    # --- dict and list methods ----------------------------------------------------------
    ("dict methods", "{% set e = {'a': 1} %}{{ e.copy() }} {{ e.get('a') }} {{ e.get('z', 0) }} {% set _ = e.update({'b': 2}, c=3) %}{{ e }} {{ e.pop('a') }} {{ e.pop('z', 'none') }} {{ e }} {{ e.setdefault('c', 9) }} {{ e.setdefault('f', 4) }} {{ e }} {{ e.popitem() }} {% set _ = e.clear() %}{{ e }}", None, None),
    ("dict pop missing", "{% set e = {} %}{{ e.pop('k') }}", None, None),
    ("list methods", "{% set l = [3, 1, 2] %}{{ l.index(1) }} {{ l.count(3) }} {% set _ = l.sort() %}{{ l }} {% set _ = l.sort(reverse=true) %}{{ l }} {% set _ = l.reverse() %}{{ l }} {{ l.pop() }} {{ l.pop(0) }} {% set _ = l.insert(0, 9) %}{{ l }} {% set _ = l.extend([7, 8]) %}{{ l }} {% set _ = l.remove(9) %}{{ l }} {{ l.copy() }} {% set _ = l.append((1, 2)) %}{{ l }} {% set _ = l.clear() %}{{ l }}", None, None),
    ("list method errors", "{{ [1].index(5) }}", None, None),
    ("sort mixed types", "{% set l = [1, 'a'] %}{{ l.sort() }}", None, None),
    ("tuple methods", "{{ (1, 2, 1).count(1) }} {{ (1, 2).index(2) }}", None, None),
    ("tuple has no append", "{{ (1,).append(2) }}", None, None),
    ("unknown method", "{{ 'x'.nope() }}", None, None),
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
    ("import exports top-level variables", "{% import 'm.sql' as m %}{{ m.v }} {{ m._p is defined }} {{ m.n is defined }} {{ m.inloop is defined }} {{ m.inif }} {{ m._m is defined }} {{ m.f() }}", {"m.sql": "{% set v = 3 %}{% set _p = 1 %}{% import 'n.sql' as n %}{% macro _m() %}{% endmacro %}{% macro f() %}F{% endmacro %}{% for i in [1] %}{% set inloop = 1 %}{% endfor %}{% if true %}{% set inif = 2 %}{% endif %}", "n.sql": ""}, None),
    ("from import a variable", "{% from 'm.sql' import v, w %}{{ v }}{{ w }}", {"m.sql": "{% set v = 3 %}{% set w = v * 2 %}"}, None),
    ("import with context sees the caller", "{% set y = 1 %}{% import 'm.sql' as m with context %}{{ m.f() }} {% from 'm.sql' import f with context %}{{ f() }}", {"m.sql": "{% macro f() %}{{ y }}-{{ x }}{% endmacro %}"}, None),
    ("import with context sees loop variables", "{% for y in [7] %}{% import 'm.sql' as m with context %}{{ m.f() }}{% endfor %}", {"m.sql": "{% macro f() %}{{ y }}{% endmacro %}"}, None),
    ("import without context", "{% set y = 1 %}{% import 'm.sql' as m without context %}{{ m.f() }}", {"m.sql": "{% macro f() %}{{ y is defined }}{{ x is defined }}{% endmacro %}"}, None),
    ("from import without context", "{% from 'm.sql' import f without context %}{{ f() }}", {"m.sql": "{% macro f() %}{{ x is defined }}{% endmacro %}"}, None),
    # --- block set, with, do -------------------------------------------------------------
    ("block set", "{% set q %}\nSELECT {{ x }}\n{% endset %}[{{ q }}] {% set w | upper %}abc{% endset %}{{ w }} {% set v | replace('a', 'b') | upper %}aa{% endset %}{{ v }}", {}, None),
    ("block set has its own scope", "{% set q %}{% set inner = 1 %}in{% endset %}{{ q }} {{ inner is defined }}", {}, None),
    ("block set in a loop", "{% for i in [1, 2] %}{% set q %}v{{ i }}{% endset %}{{ q }}{% endfor %}", {}, None),
    ("with", "{% set a = 'outer' %}{% with a = 1, b = a %}{{ a }}{{ b }}{% set c = 3 %}{{ c }}{% endwith %}{{ a }} {{ c is defined }}", {}, None),
    ("with without values", "{% with %}{% set q = 1 %}{{ q }}{% endwith %}{{ q is defined }}", {}, None),
    ("do", "{% set l = [] %}{% do l.append(1) %}{% do l.extend([2, 3]) %}{{ l }}", {}, None),
    # --- loops ---------------------------------------------------------------------------
    ("loop filter", "{% for x in range(6) if x is not none and x % 2 == 0 %}{{ x }}/{{ loop.index }}/{{ loop.length }}/{{ loop.last }};{% else %}none{% endfor %}", {}, None),
    ("loop filter else", "{% for x in range(3) if x > 5 %}{{ x }}{% else %}none{% endfor %}", {}, None),
    ("loop filter with two targets", "{% for k, v in d.items() if v is number %}{{ k }}{% endfor %}", {}, None),
    ("loop helpers", "{% for x in [1, 1, 2] %}{{ loop.cycle('a', 'b') }}{{ loop.previtem is defined }}{{ loop.nextitem|default('-') }}{{ loop.changed(x) }}{{ loop.depth }}{{ loop.depth0 }};{% endfor %}", {}, None),
    ("previtem undefined", "{% for x in [1] %}{{ loop.previtem }}{% endfor %}", {}, None),
    ("recursive loop", "{% for x in tree recursive %}<{{ x.n }}{{ loop.depth }}{% if x.c %}[{{ loop(x.c) }}]{% endif %}>{% endfor %}", {}, None),
    ("recursive loop nested loop variable", "{% for x in tree recursive %}{{ loop.index }}{{ loop(x.c) }}{% endfor %}", {}, None),
    ("calling a non recursive loop", "{% for x in [1] %}{{ loop([]) }}{% endfor %}", {}, None),
    ("break and continue", "{% for x in range(6) %}{% if x == 1 %}{% continue %}{% endif %}{% if x == 4 %}{% break %}{% endif %}{{ x }}{% endfor %}", {}, None),
    ("break in nested loops", "{% for a in range(3) %}{% for b in range(3) %}{% if b == 1 %}{% break %}{% endif %}{{ a }}{{ b }} {% endfor %}{% endfor %}", {}, None),
    ("continue keeps the loop variables", "{% for x in range(4) %}{% if loop.first %}{% continue %}{% endif %}{{ loop.index }}{% endfor %}", {}, None),
    # --- filter blocks, call blocks, macros ------------------------------------------------
    ("filter block", "{% filter upper %}a{{ x }}b{% endfilter %} {% filter upper|replace('A', 'x') %}abc{% endfilter %} {% filter replace('a', 'b') %}aa{% endfilter %}", {}, None),
    ("call block", "{% macro wrap(tag) %}<{{ tag }}>{{ caller() }}</{{ tag }}>{% endmacro %}{% call wrap('b') %}x={{ x }}{% endcall %}", {}, None),
    ("call block with arguments", "{% macro each(xs) %}{% for v in xs %}{{ caller(v, loop.index) }}{% endfor %}{% endmacro %}{% call(v, i) each(['a', 'b']) %}{{ i }}:{{ v }} {% endcall %}", {}, None),
    ("caller undefined without call", "{% macro m() %}{{ caller is defined }}{% endmacro %}{{ m() }}", {}, None),
    ("call block into macro without caller", "{% macro m() %}x{% endmacro %}{% call m() %}y{% endcall %}", {}, None),
    ("macro varargs and kwargs", "{% macro m(a, b=1) %}{{ a }}{{ b }}{{ varargs }}{{ kwargs }}{% endmacro %}{{ m(1, 2, 3, c=4) }} {{ m(0) }}", {}, None),
    ("macro attributes", "{% macro m(a, b=1) %}{{ varargs }}{% endmacro %}{% macro n() %}{{ caller() }}{{ kwargs }}{% endmacro %}{{ m.name }} {{ m.arguments }} {{ m.catch_varargs }} {{ m.catch_kwargs }} {{ m.caller }} {{ n.caller }} {{ n.catch_kwargs }}", {}, None),
    ("macro argument twice", "{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, a=2) }}", {}, None),
    ("macro defaults see earlier arguments", "{% macro m(a, b=a * 2) %}{{ a }}{{ b }}{% endmacro %}{{ m(3) }}", {}, None),
    ("star arguments", "{% macro m(a, b, c=0) %}{{ a }}{{ b }}{{ c }}{% endmacro %}{{ m(*[1, 2]) }} {{ m(**{'a': 3, 'b': 4}) }} {{ m(1, *[2], **{'c': 5}) }} {{ '{}-{}'.format(*items) }} {{ 'a b'.split(*[' ']) }}", {}, None),
    ("star arguments in filters", "{{ items|join(*['-']) }} {{ 'abc'|replace(**{'old': 'b', 'new': 'x'}) }}", {}, None),
    # --- include --------------------------------------------------------------------------
    ("include", "{% set y = 'Y' %}A{% include 'inc.sql' %}B", {"inc.sql": "[{{ y }}|{{ x }}]"}, None),
    ("include sees loop variables", "{% for loc in [1, 2] %}{% include 'inc.sql' %}{% endfor %}", {"inc.sql": "{{ loc }}"}, None),
    ("include without context", "{% set y = 'Y' %}{% include 'inc.sql' without context %}", {"inc.sql": "{{ y is defined }}{{ x is defined }}"}, None),
    ("include with context", "{% set y = 'Y' %}{% include 'inc.sql' with context %}", {"inc.sql": "{{ y }}"}, None),
    ("include ignore missing", "a{% include 'nope.sql' ignore missing %}b", {}, None),
    ("include a list", "{% include ['nope.sql', 'inc.sql'] %}", {"inc.sql": "second"}, None),
    ("include missing", "{% include 'nope.sql' %}", {}, None),
    ("include sets stay inside", "{% include 'inc.sql' %}{{ z is defined }}", {"inc.sql": "{% set z = 1 %}"}, None),
    ("include an expression", "{% set name = 'inc' %}{% include name ~ '.sql' %}", {"inc.sql": "ok"}, None),
    ("include error line", "{% include 'inc.sql' %}", {"inc.sql": "a\n{{ missing }}"}, None),
    # --- extends and blocks -------------------------------------------------------------------
    ("extends", "before{% extends 'base.sql' %}after{% block a %}child-a {{ super() }}{% endblock %}", {"base.sql": "B<{% block a %}base-a{% endblock %}>{% block b %}base-b{% endblock %}"}, None),
    ("extends sees top-level variables", "{% extends 'base.sql' %}{% set top = 1 %}{% block a %}{{ top }}{% endblock %}", {"base.sql": "<{% block a %}{% endblock %}>{{ top is defined }}{{ x }}"}, None),
    ("extends self", "{% extends 'base.sql' %}{% block b %}[{{ self.a() }}]{% endblock %}", {"base.sql": "{% block a %}A{% endblock %}{% block b %}B{% endblock %}"}, None),
    ("three levels and super", "{% extends 'mid.sql' %}{% block a %}3{{ super() }}{% endblock %}", {"mid.sql": "{% extends 'base.sql' %}{% block a %}2{{ super() }}{% endblock %}", "base.sql": "[{% block a %}1{% endblock %}]"}, None),
    ("super without parent", "{% block a %}{{ super() }}{% endblock %}", {}, None),
    ("required block missing", "{% extends 'req.sql' %}", {"req.sql": "{% block r required %}{% endblock %}"}, None),
    ("required block given", "{% extends 'req.sql' %}{% block r %}R{% endblock %}", {"req.sql": "<{% block r required %}{% endblock %}>"}, None),
    ("required block with content", "{% block r required %}x{% endblock %}", {}, None),
    ("scoped block", "{% for item in [1, 2] %}{% block s scoped %}{{ item }}{% endblock %}{% endfor %}", {}, None),
    ("unscoped block", "{% for item in [1, 2] %}{% block s %}{{ item is defined }}{% endblock %}{% endfor %}", {}, None),
    ("block sees top-level set", "{% set t = 5 %}{% block z %}{{ t }}{% endblock %}", {}, None),
    ("nested blocks", "{% extends 'base.sql' %}{% block inner %}I2{% endblock %}", {"base.sql": "{% block outer %}O({% block inner %}I1{% endblock %}){% endblock %}"}, None),
    ("block defined twice", "{% block a %}{% endblock %}{% block a %}{% endblock %}", {}, None),
    ("endblock with name", "{% block a %}x{% endblock a %}", {}, None),
    ("extends twice", "{% extends 'base.sql' %}{% extends 'base.sql' %}", {"base.sql": "x"}, None),
    ("extends an expression", "{% extends 'ba' ~ 'se.sql' %}{% block a %}c{% endblock %}", {"base.sql": "[{% block a %}{% endblock %}]"}, None),
    ("macro in extending template", "{% extends 'base.sql' %}{% macro m() %}M{% endmacro %}{% block a %}{{ m() }}{% endblock %}", {"base.sql": "[{% block a %}{% endblock %}]"}, None),
    # --- autoescape --------------------------------------------------------------------------
    ("autoescape tag", "{% autoescape true %}{{ '<a>' }}{{ '<b>'|safe }}{% endautoescape %}{{ '<c>' }}", {}, None),
    # --- slices --------------------------------------------------------------------------------
    ("slices", "{{ 'hello'[1:3] }} {{ 'hello'[::-1] }} {{ [1, 2, 3, 4][::2] }} {{ (1, 2, 3)[1:] }} {{ 'abc'[-2:] }} {{ items[:-1] }} {{ items[5:] }} {{ items[-10:2] }} {{ '中文字'[1:] }} {{ [1, 2, 3][::-2] }} {{ items[1:2:0] if false else 'x' }}", {}, None),
    ("slice step zero", "{{ items[::0] }}", {}, None),
    ("slice of a number", "{{ x[1:] }}", {}, None),
    # --- namespace, dict, cycler, joiner, lipsum ---------------------------------------------
    ("namespace", "{% set ns = namespace(n=0, s='') %}{% for i in range(3) %}{% set ns.n = ns.n + i %}{% set ns.s = ns.s ~ i %}{% endfor %}{{ ns.n }} {{ ns.s }} {{ ns }} {{ ns.missing is defined }}", {}, None),
    ("namespace from a dict", "{% set ns = namespace({'a': 1}, b=2) %}{{ ns.a }}{{ ns.b }}", {}, None),
    ("set attribute of a dict", "{% set e = {} %}{% set e.x = 1 %}", {}, None),
    ("dict global", "{{ dict(a=1, b=2) }} {{ dict() }} {{ dict({'z': 1}, y=2) }} {{ dict([('k', 'v')]) }}", {}, None),
    ("cycler", "{% set c = cycler('a', 'b') %}{{ c.next() }}{{ c.next() }}{{ c.current }}{{ c.next() }}{% do c.reset() %}{{ c.current }}{{ c.next() }}", {}, None),
    ("joiner", "{% set j = joiner('|') %}{% for x in items %}{{ j() }}{{ x }}{% endfor %} {% set k = joiner() %}{{ k() }}a{{ k() }}b", {}, None),
    ("lipsum shape", "{{ lipsum(2, false, 5, 6).split('\\n\\n')|length }} {{ lipsum(1, min=3, max=4).startswith('<p>') }}", {}, None),
    ("kwargs keep their order", "{% macro m() %}{{ kwargs }}{% endmacro %}{{ m(z=1, a=2, m=3) }} {{ m(**{'b': 1, 'a': 2}) }}", {}, None),
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
    if isinstance(e, jinja2.TemplateRuntimeError):
        return "value"
    if isinstance(e, (TypeError, ZeroDivisionError, ValueError, LookupError, AttributeError)):
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
            extensions=EXTENSIONS,
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
