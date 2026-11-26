{# The middle level: extends page.sql, fills title and extends body with super(). #}
{% extends 'parts/page.sql' %}
{% block title %}a page{% endblock %}
{% block body %}section, then {{ super() }}{% endblock %}
