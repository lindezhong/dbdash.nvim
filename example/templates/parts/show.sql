{# Rows of the template examples: what was written and what it gave (as text).
   show(code, value) is one row; rows(list) is a UNION ALL of [code, output] pairs, where
   the code is the template exactly as written and the output what it rendered. #}
{% macro show(code, value) -%}
SELECT {{ code | sql_quote }} AS template, {{ value | string | sql_quote }} AS result
{%- endmacro %}
{% macro rows(list) -%}
{% for code, out in list %}
{{ 'UNION ALL ' if not loop.first }}SELECT {{ code | string | sql_quote }} AS template, {{ out | string | sql_quote }} AS result
{% endfor %}
{%- endmacro %}
