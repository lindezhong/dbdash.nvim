{# The layout of a report query. A config extends it and fills the blocks; whatever a
   block does not replace stays as written here ({{ super() }} keeps it inside the
   replacement). Paths are relative to the config file. A tag ending in "+%}" keeps the
   line break after it (trim_blocks would remove it and join the lines). #}
{% include 'templates/players.sql' +%}
SELECT {% block columns %}round(avg(score), 1) AS avg_score{% endblock +%}
FROM players
WHERE {% block where %}1 = 1{% endblock +%}
{% block rest %}{% endblock %}
