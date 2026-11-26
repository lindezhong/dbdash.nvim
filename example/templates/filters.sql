{# Included where the query needs it: it sees args and meta, and the including
   template's own variables (here min_score). #}
team IN {{ args.teams | sql_in }} AND score >= {{ min_score }}
