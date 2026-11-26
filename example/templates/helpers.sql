{# Macros for templates.yaml. #}
{% macro count_if(column, value) -%}
sum(CASE WHEN {{ column }} = {{ value | sql_quote }} THEN 1 ELSE 0 END)
{%- endmacro %}

{# The caller's text (a {% call %} block) wrapped as a named column. #}
{% macro column(alias) -%}
({{ caller() }}) AS {{ alias | sql_id }}
{%- endmacro %}
