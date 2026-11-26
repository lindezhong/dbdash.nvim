{# One row of the template examples: what was written and what it gave (as text). #}
{% macro show(code, value) -%}
SELECT {{ code | sql_quote }} AS template, {{ value | string | sql_quote }} AS result
{%- endmacro %}
