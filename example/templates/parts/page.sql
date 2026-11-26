{# Base of the "extends" panel in inheritance.yaml: title is required, body has a default,
   the loop shows a scoped block (it sees the loop variable). #}
SELECT '{% block title required %}{% endblock %}' AS part, '{% block body %}base body{% endblock %}' AS text
{% for n in [1, 2] %}
UNION ALL SELECT 'scoped {{ n }}', '{% block line scoped %}line {{ n }}{% endblock %}'
{% endfor %}
UNION ALL SELECT 'self.title()', '{{ self.title() }}'
