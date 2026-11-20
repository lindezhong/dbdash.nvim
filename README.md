# dbdash.nvim

Database dashboards inside Neovim: periodically run a query and render the result as a
table or a terminal chart (line, area, bar, histogram, boxplot, heatmap, scatter, bubble,
pie). Pure Lua for Neovim 0.12+, with no external dependencies: no Python, no database
CLIs. Wire protocols, TLS 1.3 and the cryptography are implemented in Lua; SQLite goes
through LuaJIT FFI and the system `libsqlite3`.

Databases: SQLite, PostgreSQL, MySQL, Redis, MongoDB, Cassandra, SQL Server.

```yaml
database:
  url: "postgres://user:pass@db.internal:5432/app?tls=pin&fingerprint=sha256:AB:CD:..."
query:
  sql: |
    SELECT date_trunc('hour', created_at) AS hour, count(*) AS signups
    FROM users
    WHERE created_at > now() - interval '{{ hours }} hours'
    GROUP BY 1 ORDER BY 1
  args:
    - name: hours
      type: int
      default: 24
show:
  type: line
  title: Signups per hour
  x_column: hour
  y_column: signups
  interval: 60s
```

`:DbDashStart signups.yaml hours=48`, or `:DbDash` for a sidebar of the configs in the
current directory. See `:help dbdash`.

## Development

```sh
make test                  # unit, golden and UI tests (clones mini.nvim into deps/)
make test FILE=tests/yaml/test_parse.lua
UPDATE_GOLDEN=1 make test  # regenerate render reference outputs
make it                    # also run integration tests against tests/docker/compose.yaml
make it-down
```

Test expectations for the template engine and YAML parser come from real Jinja2 and
PyYAML (`tests/template/gen.py`, `tests/yaml/gen.py`); they are only needed to
regenerate cases.
