{# Macros shared by dashboards. Import with
     {% import 'macros/sql_helpers.sql' as h %}  or  {% from 'macros/sql_helpers.sql' import in_list %}
   Paths are relative to the config file; imported templates do not see the caller's
   variables, so pass everything as arguments. Column names use | safe so they stay SQL
   when the calling config enables query.autoescape. #}
{% macro in_list(column, values) %}
{{ column | safe }} IN {{ values | sql_in }}
{%- endmacro %}

{% macro between(column, low, high) -%}
{{ column | safe }} BETWEEN {{ low }} AND {{ high }}
{%- endmacro %}

{% macro bucket(column, size=10) -%}
({{ column | safe }} / {{ size }}) * {{ size }}
{%- endmacro %}
