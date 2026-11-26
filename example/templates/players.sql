{# Sample data (included by report.sql and templates.yaml): 60 players in three teams. #}
WITH RECURSIVE players(id, team, score) AS (
  SELECT 1, 'red', abs(random() % 100)
  UNION ALL
  SELECT id + 1, CASE id % 3 WHEN 0 THEN 'red' WHEN 1 THEN 'blue' ELSE 'green' END,
         abs(random() % 100)
  FROM players WHERE id < 60
)
