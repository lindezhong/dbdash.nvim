{# Imported for its top-level variables (names starting with _ stay private) and a macro
   that reads the importer's variables when imported "with context". #}
{% set version = 3 %}
{% set _private = 'hidden' %}
{% macro greet() %}hello {{ who | default('nobody') }}{% endmacro %}
