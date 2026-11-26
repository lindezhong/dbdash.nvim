{# Macros shared by dashboards. Import with
     {% import 'macros/sql_helpers.sql' as h %}  or  {% from 'macros/sql_helpers.sql' import in_list %}
   Paths are relative to the config file. Imported templates see args and meta, but not
   the caller's own variables (set, for) unless imported "with context": pass those as
   arguments. Column names use | safe
   so they stay SQL when the calling config enables query.autoescape; | sql_quote quotes
   values whether autoescape is on or not. #}
{% macro in_list(column, values) %}
{{ column | safe }} IN {{ values | sql_in }}
{%- endmacro %}

{% macro between(column, low, high) -%}
{{ column | safe }} BETWEEN {{ low }} AND {{ high }}
{%- endmacro %}

{% macro bucket(column, size=10) -%}
({{ column | safe }} / {{ size }}) * {{ size }}
{%- endmacro %}

{# `column` is passed in; args.label is an argument of the dashboard, meta.config_name
   its config file name. #}
{% macro labelled(column) -%}
{{ column | safe }} || ' / ' || {{ args.label | sql_quote }} || ' / ' || {{ meta.config_name | sql_quote }}
{%- endmacro %}
