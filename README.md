# dbdash.nvim

Database dashboards inside Neovim: run a query on an interval and show the result as a
table or a terminal chart. Pure Lua for Neovim 0.12+, with no external dependencies: no
Python, no database command-line tools. Wire protocols, TLS 1.2/1.3 and the cryptography
are implemented in Lua; SQLite goes through LuaJIT FFI and the system `libsqlite3`.

- **Databases**: SQLite, PostgreSQL, MySQL/MariaDB, Redis, MongoDB (including
  `mongodb+srv://`), Cassandra, SQL Server, and HTTP APIs (`https://`, with cookies).
- **Charts**: table, line, area, bar, histogram, boxplot, heatmap, scatter, bubble, pie,
  stat (a KPI value in large digits with its change and a sparkline), text (the result as
  plain text, e.g. log lines or a command's output),
  each with alternative renderers (braille / block canvases, vertical bars, round pie, ...).
- **Style sheets**: all appearance is CSS: selectors (elements, `#id`, `.class`,
  attributes, `:nth-child`, descendants), a cascade from the defaults through `setup()`,
  the dashboard and each panel to run-time changes, and properties after CSS (colors,
  borders, padding, CSS Grid for the layout, text wrapping, `display`, ...). The rendering
  is layered like a browser's (DOM, style, layout, paint, composite, events), redraws only
  what changed, and `:DbDashInspect` shows the rules and computed style of what is under
  the cursor.
- **Several panels** per dashboard in a grid, each with its own database (mix SQLite,
  PostgreSQL, an HTTP API, ...) and interval, plus an optional refresh of all of them; the
  top-level `database`, `query` and `show` are defaults every panel can override.
  Dashboards that are not on screen pause and catch up when shown again (or keep
  refreshing with `show.refresh_hidden`); closing a dashboard's last window stops it.
- **Title and descriptions**: a header with the dashboard's title and a countdown;
  descriptions of the dashboard and each chart are templates shown as Markdown (`K`).
- **Lua**: a `lua://` source whose query is Lua code, and `query.transform` to reshape any
  result with Lua before it is checked as rows (trusted configs only, as with `exrc`);
  a `store` table kept per panel, run records with the previous results (`meta.prev_ok`),
  `dbdash.run()` to run a panel's query again with other arguments, and assigning
  arguments from templates and Lua.
- **Query templates**: Jinja2 (statements, filters, tests and functions, checked against
  Jinja2 itself), with SQL-safe quoting filters and autoescape; include, extends and
  imports from files next to the config.
- **Cancelling**: a refresh you ask for, stopping a dashboard and timeouts cancel the
  running query, on the server too (PostgreSQL, MySQL, SQL Server, MongoDB, SQLite, Lua).
- **Push sources**: data that arrives instead of being queried: `luastream://` (Lua that
  prints), `exec://` (a script's output, like `tail -f`) and `webhook://` (an HTTP endpoint
  described by an OpenAPI 3.1 document, validated with JSON Schema, secured after MCP's
  rules). Items are processed one at a time; the panel shows new data at most once per
  interval.
- **Thresholds**: classes on values (stat cards, table cells and rows), colored by style
  sheets, and notify when a value crosses a level.
- **Arguments**: typed variables set from the command line, prompts or in the dashboard;
  shared by all panels or a panel's own.
- **Sidebar**: browse config files and subdirectories as a tree, start and stop dashboards.
- **Sessions**: dashboards come back with `:mksession`; changed arguments can be kept too.
- **TLS**: `require`, certificate pinning, `verify-ca` / `verify-full` against the system
  CA store or a CA bundle.

## Requirements

- Neovim 0.12 or newer (LuaJIT build, which is the default).
- SQLite dashboards need the system SQLite library (`libsqlite3.so.0` on Linux,
  `libsqlite3.dylib` on macOS, `sqlite3.dll` / `winsqlite3.dll` on Windows), or
  `database.options.lib_path`. Other databases need nothing extra.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "lindezhong/dbdash.nvim",
  -- Load at startup: the plugin file only defines commands, mappings and autocmds
  -- (modules load on first use), and sessions need its dbdash:// buffer handler.
  lazy = false,
  opts = { -- optional, see :help dbdash-setup
    sidebar = { width = "25%" },     -- columns or a percentage of the editor
    dashboard = { open = "vsplit" }, -- where :DbDashStart shows a dashboard
  },
}
```

With the built-in package manager:

```lua
vim.pack.add({ "https://github.com/lindezhong/dbdash.nvim" })
```

`setup()` is optional. The help tags come with the plugin (`doc/tags`): `:help dbdash` works
right after installing it.
`:checkhealth dbdash` checks the plugin; `:checkhealth dbdash.sqlite` (or `.postgres`,
`.mongodb`, ...) checks what one database needs, such as the SQLite library or CA
certificates.

## Quick start

Save a config, e.g. `signups.yaml`:

```yaml
database:
  url: "postgres://user:pass@db.internal:5432/app?tls=verify-full"
query:
  sql: |
    SELECT date_trunc('hour', created_at) AS hour, count(*) AS signups
    FROM users
    WHERE created_at > now() - make_interval(hours => {{ args.hours }})
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

Then `:DbDashStart signups.yaml hours=48`, or `:DbDash` for a sidebar listing the configs
of the current directory as a tree: `<CR>` on a directory expands it, on a file starts its
dashboard; `●` marks running dashboards, `◐` paused ones (not on screen), `○` the others
(closing a dashboard's last window stops it).

To try it without a database server, open a file in [`example/`](example): most use an
in-memory SQLite database (`connections/github.yaml` and `dashboards/multi_panel.yaml` also
call the GitHub API).

## Usage

| Command | Description |
| --- | --- |
| `:DbDashStart[!] {config} [name=value ...]` | Start a dashboard (`!` asks for every argument; `<panel>.name=value` sets one panel's own) |
| `:DbDashRestart` | Refresh now |
| `:DbDashStop [{config}]` | Stop a dashboard (closing its last window does too) |
| `:DbDashList` / `:DbDashStatus` | Running dashboards / status and query history |
| `:DbDash` / `:DbDashClose` | Open / close the sidebar |
| `:DbDashShowVariables`, `:DbDashModifyVariable`, `:DbDashUpdateVariable {name} {value}`, `:DbDashResetVariables` | Show and change arguments |
| `:DbDashShowSQL` | Show the rendered query |
| `:DbDashDescribe` | Show the description of the dashboard or the panel under the cursor (Markdown) |
| `:DbDashExport[!] [csv\|tsv\|json\|markdown] [{file}]` | Export the result to a register or a file |
| `:DbDashStyle {type} [{renderer}]`, `:DbDashStyle set {selector} {property} {value}` | Change the style at run time, e.g. `:DbDashStyle line asciichart`, `:DbDashStyle set value color DiagnosticOk` |
| `:DbDashInspect [{element}]` | The element under the cursor: its matched rules, computed style and box |
| `:DbDashTrust [allow\|deny\|remove] [{config}]` | Decide about a config that runs Lua without the question |
| `:DbDashMksession[!] [{file}]` | Write a session (any `:mksession` restores dashboards) |

In a dashboard: `r` refresh, `a` modify an argument, `A` show arguments, `R` reset
arguments, `s` show the query, `e` export the result, `K` show the description (`ⓘ` marks
titles that have one). Global mappings: `<leader>ds` start, `<leader>dr` refresh,
`<leader>dt` stop, `<leader>dl` list, `<leader>dd` sidebar.

Every key, the sidebar (width, position, directory, file globs, cursor line), where
dashboards open, the popup border and size, the default interval, timeouts and row limit,
the `dbdash.run()` limits and the push sources' queue can be set in `setup()`, and your
own style sheet for every dashboard (`setup({ style = { ... } })`); see
`:help dbdash-setup`. The default colors are highlight groups (`:help dbdash-highlights`),
e.g. `DbDashSidebarDir` for sidebar directories.

### Sessions

Dashboard buffers are named `dbdash://<config path>`, so a session written by `:mksession`
(or any session manager) reopens and restarts them, also when `'sessionoptions'` lacks
`blank`. They restart with default arguments; to keep the changed ones, save and load them
next to the session file from your session setup:

```lua
require("dbdash").mksession(session_file .. ".dbdash")   -- after :mksession
require("dbdash").load_session(session_file .. ".dbdash") -- after sourcing the session
```

## Configuration

A config file describes one dashboard: `database`, `query` and `show`, or `panels` for
several charts, and a `style` sheet for how it looks. Top-level bare fields are
dashboard-wide: `interval` (a refresh of every panel), `args` (shared arguments), `style`,
the header's `title` and `description`. The top-level `database`, `query` and `show` are
defaults each panel can override (a panel's own `database`, `show.interval`, ...); fields
of one chart (`query.sql`, `show.type`, ...) belong in each panel. A panel's `query.args`
are its own. A config is checked when it loads (fields, arguments, the database URL and
the driver's options, chart types, style sheets, the grid), each problem with its line and
column. See `:help dbdash-config`.

Style sheets map selectors to CSS properties, at the top level (the dashboard's), in a
panel (only its own elements) and in `setup()` (every dashboard):

```yaml
style:
  dashboard: { grid-template-columns: "2fr 1fr", column-gap: 2 }
  panel-title: { font-weight: bold }
  "#orders series": { color: "#61afef" }
  "row:nth-child(even)": { background-color: "#2c313a" }
  value.danger: { background-color: DiagnosticError }   # a threshold's class
panels:
  - id: orders
    query: { sql: "SELECT ..." }
    show: { type: line, x_column: day, y_column: total }
    style:
      panel: { grid-column: "span 2" }
      chart: { canvas: quadrant }
```

The grid is CSS Grid: tracks (`30`, `"25%"`, `"2fr"`, `auto`, `"minmax(10, 1fr)"`), named
areas, and panels placed by `grid-area`, `grid-row` / `grid-column` or into the next free
cells. Rows get at least each chart's smallest readable plot (`plot { min-height }`) and
share the rest of the window; a grid taller than the window scrolls instead of squeezing
the charts. Each chart type takes the options of the common chart libraries (Chart.js,
ECharts, Grafana, DataTables): stacked and grouped series, reference lines, log axes,
doughnuts, reduce functions, sorting, row classes, and more; long table cells wrap. See
`:help dbdash-css`, `:help dbdash-layout`, `:help dbdash-charts` and
[`example/charts/`](example/charts), where every option has its own panel.

[`example/dbdash.schema.yaml`](example/dbdash.schema.yaml) is a JSON Schema of the whole
format (also in `:help dbdash-schema`, with a tag for every field); editors with
yaml-language-server validate and complete a config that starts with:

```yaml
# yaml-language-server: $schema=/path/to/dbdash.nvim/example/dbdash.schema.yaml
```

Examples are in [`example/`](example), one directory per topic (`:help dbdash-examples`):

| Directory | Shows |
| --- | --- |
| [`charts/`](example/charts) | style sheets: selectors, the cascade and the common properties ([`css.yaml`](example/charts/css.yaml)); one file per chart type with every renderer and option, one panel each ([`line.yaml`](example/charts/line.yaml), [`bar.yaml`](example/charts/bar.yaml), [`pie.yaml`](example/charts/pie.yaml), [`table.yaml`](example/charts/table.yaml), [`stat.yaml`](example/charts/stat.yaml), ...) |
| [`dashboards/`](example/dashboards) | several panels in a grid ([`multi_panel.yaml`](example/dashboards/multi_panel.yaml): defaults, intervals, a database per panel, title, countdown, descriptions, argument lines); a grid laid out with CSS Grid properties ([`grid.yaml`](example/dashboards/grid.yaml): column and row tracks, areas, placement); a database next to a source that sends data, with the top-level interval ([`pull_push.yaml`](example/dashboards/pull_push.yaml)); errors and backing off ([`errors.yaml`](example/dashboards/errors.yaml)) |
| [`templates/`](example/templates) | arguments ([`arguments.yaml`](example/templates/arguments.yaml)); every statement ([`statements.yaml`](example/templates/statements.yaml)), filter ([`filters.yaml`](example/templates/filters.yaml)), test, function and expression ([`tests_functions.yaml`](example/templates/tests_functions.yaml)) and method ([`methods.yaml`](example/templates/methods.yaml)); SQL filters and autoescape ([`sql.yaml`](example/templates/sql.yaml)); macros ([`macros.yaml`](example/templates/macros.yaml)); extends / include / import ([`inheritance.yaml`](example/templates/inheritance.yaml)); Lua in templates ([`template_lua.yaml`](example/templates/template_lua.yaml)); every `meta` field ([`meta.yaml`](example/templates/meta.yaml)) |
| [`lua/`](example/lua) | a `lua://` source ([`lua.yaml`](example/lua/lua.yaml)), `query.transform` ([`transform.yaml`](example/lua/transform.yaml)), panel state, callbacks and run records ([`callback.yaml`](example/lua/callback.yaml)) |
| [`push/`](example/push) | push sources: [`luastream.yaml`](example/push/luastream.yaml) (with `dbdash.run()` on an item), [`exec.yaml`](example/push/exec.yaml), [`webhook.yaml`](example/push/webhook.yaml) (OpenAPI: a GET without a token, a POST with one) |
| [`databases/`](example/databases) | a SQLite file ([`sqlite_file.yaml`](example/databases/sqlite_file.yaml)); after `make it-up` (the test services in docker): [`postgres.yaml`](example/databases/postgres.yaml), [`mysql.yaml`](example/databases/mysql.yaml), [`redis.yaml`](example/databases/redis.yaml), [`mongodb.yaml`](example/databases/mongodb.yaml), [`cassandra.yaml`](example/databases/cassandra.yaml), [`mssql.yaml`](example/databases/mssql.yaml), [`http.yaml`](example/databases/http.yaml) |
| [`connections/`](example/connections) | after `make it-up`: TLS modes ([`tls.yaml`](example/connections/tls.yaml)), passwords outside the config ([`passwords.yaml`](example/connections/passwords.yaml)), cancelling a slow query ([`cancel.yaml`](example/connections/cancel.yaml)); an HTTPS API ([`github.yaml`](example/connections/github.yaml), needs network) |

### Connection URLs

```text
sqlite:///absolute/path.db    sqlite://relative/to/config.db    sqlite:///:memory:
postgres://user:pass@host:5432/db
mysql://user:pass@host:3306/db
redis://[user]:pass@host:6379/0                      (rediss:// for TLS)
mongodb://user:pass@host:27017/db?authSource=admin
mongodb://user:pass@h1:27017,h2:27017/db?readPreference=secondaryPreferred
mongodb+srv://user:pass@cluster0.example.net/db
cassandra://user:pass@host:9042/keyspace?consistency=LOCAL_QUORUM
mssql://user:pass@host:1433/db
lua://                                               (the query is Lua code)
https://api.example.com/v1                           (or http://; the query is a request)
luastream://   exec://   webhook://127.0.0.1:8765/hooks   (push sources, see below)
```

Passwords do not have to be in config files: use `${ENV_VAR}` in the URL,
`database.password_cmd` (e.g. `pass show db/app`), or
`~/.local/share/nvim/dbdash/passwords.json` (`:help dbdash-passwords`).

Common parameters: `tls=disable|require|pin|verify-ca|verify-full`,
`fingerprint=sha256:...` (for `pin`), `ca=bundle.pem`, `tls_host=name`,
`connect_timeout=10s`, `timeout=30s` (defaults changeable in `setup({ defaults })`); a
query that runs out of time is stopped on the server too (`:help dbdash-cancel`).
Passwords are percent-decoded. Also accepted: `sqlite3://`, `postgresql://`, `mariadb://`,
`cql://`, `sqlserver://`. The query language follows the database: SQL, CQL, one Redis
command, a JSON document for MongoDB, Lua for `lua://`, a curl command for HTTP.
Details: `:help dbdash-databases` and `:help dbdash-tls`.

### Templates

```sql
SELECT * FROM orders
WHERE status = {{ args.status | sql_quote }}
  AND region IN {{ args.regions | sql_in }}
{% if args.since %}
  AND created_at >= {{ args.since | sql_quote }}
{% endif %}
  AND source = {{ meta.config_name | sql_quote }}
ORDER BY {{ args.sort | sql_id }}
LIMIT {{ args.limit | sql_limit }}
```

Arguments are `args.<name>` and metadata (config file and directory, database, panel,
time, OS, the previous results and run records, ...) `meta.<name>`, in templates and in
Lua code alike. `query.sql`, `query.transform` and the descriptions are all templates, and
can also run Lua:

```sql
{% import 'lua/helpers.lua' as h %}
SELECT * FROM visits WHERE day >= {{ h.since(args.days) }}
{% lua %}
  if meta.os == "windows" then return "AND host = 'win'" end
{% endlua %}
```

`{% lua %}` blocks output what their code returns; imported `.lua` modules return a table
of functions to call (`:help dbdash-template-lua`).

The SQL filters quote for the panel's database (MySQL backslashes, SQL Server
`N'...'` and `[ident]`, JSON for MongoDB, ...). See `:help dbdash-templates`.

### Lua

A `lua://` database runs its query as Lua, and `query.transform` reshapes the result of
any database:

```yaml
query:
  sql: SELECT day, amount FROM sales
  transform: |
    local out = {}
    for _, r in ipairs(rs.rows) do out[#out + 1] = { r[1], r[2] / 100 } end
    return { columns = { "day", "amount_usd" }, rows = out }
```

Scripts get `args`, `rs` (for transforms) and helpers such as `dbdash.system()` and
`dbdash.query()` that wait without blocking the editor, `store` (a table the panel keeps
while the dashboard runs), `meta.prev_ok.result` (the last successful refresh's rows) and
`dbdash.run(args)` (the panel's query again with other arguments; `meta.run.kind` tells a
callback from a refresh, `meta.run.depth` how deep a callback of callbacks is). Every
refresh and callback has a run record (`meta.run`, `meta.runs`, `meta.prev`,
`meta.prev_ok`: id, caller, times, SQL and results; `:help dbdash-runs`). Assigning `args.x`
(or `{% set args.x = v %}` in a template) sets an argument for the rest of the refresh and
keeps it (`:help dbdash-assign-args`).

dbdash asks before running a config with Lua: one question per config, covering the config
and the `.lua` files it imports, asked again when any of them changes;
`setup({ lua = { confirm = false } })` or `lua.trusted_dirs` skip that, and `:DbDashTrust`
decides without the question. See `:help dbdash-lua`.

Every query goes the same way: query, then `query.transform` if there is one, then a check
that the result is rows. SQL results pass as they are; a `lua://` value or an HTTP response
usually needs the transform (`:help dbdash-transform`).

### HTTP

`http://` and `https://` URLs call an API; `query.sql` is a curl command whose URL is a
path under the database URL:

```yaml
database:
  url: https://api.example.com/v1
query:
  autoescape: true      # {{ }} values become shell-quoted words
  sql: |
    curl -X POST /search \
      -H 'Authorization: Bearer {{ args.token }}' \
      -G --data-urlencode q={{ args.keyword }} \
      -b .cookies.txt -c .cookies.txt \
      --json '{"limit": 20}' -L
  transform: |
    local out = {}
    for _, it in ipairs(rs.data.items) do out[#out + 1] = { name = it.name, n = it.count } end
    return out
```

The options are curl's (`-X`, `-H`, `-d`, `--data-urlencode`, `--json`, `-G`, `-b`, `-c`,
`-u`, `-L`, `-k`, `-m`, ...), with curl's defaults: `-d` sends a form, redirects need
`-L`; output options such as `-s` are accepted, so a command copied with "Copy as cURL"
runs once its URL is cut down to the path. The path is appended to the URL's path as
written: `/v1` + `/search` requests `/v1/search` (a failed request names the full URL).
Cookies work as curl's: `-b` sends them, `-c` writes the cookie file (next to the config;
the config is trusted first) that a later refresh reads with `-b`. The transform gets the
decoded JSON as `rs` and `response` (status, reason, headers, body, url). A JSON list of
objects or `{"columns": [...], "rows": [...]}` shows without a transform; every result
must end up in one of these row shapes (`:help dbdash-result`). `https` verifies
certificates by default. See `:help dbdash-http`.

### Push sources

`luastream://`, `exec://` and `webhook://` receive data instead of querying it on an
interval: Lua code that prints, a script's output, or HTTP requests to a local endpoint.
Their output is cut into items (by default one per line); each item goes through
`query.transform` (or must be JSON rows), one at a time, and the panel shows new data at
most once per `show.interval`, so a fast source does not redraw for every item. A bad item
fails on its own; the source goes on.

```yaml
database:
  url: "exec://"
  options: { capture: both, cwd: logs, ok_codes: [0, 1] }
query:
  sql: tail -n 0 -F app.log
  transform: |
    store.lines = store.lines or {}
    table.insert(store.lines, 1, { stream = stream, line = rs })
    return store.lines
```

`luastream://` and `exec://` end when the code or script ends; `webhook://` listens until
the dashboard stops, takes an OpenAPI 3.1 document as `query.sql` to describe the
requests it accepts (parameters, bodies, security), and follows MCP's rules for HTTP
endpoints: 127.0.0.1 by default, a security requirement on any other address, Host and
Origin checks, limits on bodies and connections. Examples are in
[`example/push/`](example/push); see `:help dbdash-push`.

## Limitations

- Each refresh opens a new connection; there is no connection pool.
- No certificate revocation checks (CRL / OCSP); TLS 1.0/1.1, renegotiation and session
  resumption are not supported.
- The cryptography is pure Lua and not constant-time.
- SQL Server `encrypt=strict` (TDS 8) is not covered by the integration tests.
- Oracle is not supported.

## Development

How the code is put together (layers, data sources, scheduling, drawing, events) is in
[ARCHITECTURE.md](ARCHITECTURE.md).

```sh
make test                  # lint, then unit, golden and UI tests
make test FILE=tests/yaml/test_parse.lua   # one file (no lint)
make lint                  # stylua --check, luacheck, lua-language-server (Warning up)
make fmt                   # format with stylua
UPDATE_GOLDEN=1 make test  # regenerate render reference outputs
make it-up                 # start the integration services (docker compose, waits until ready)
make it                    # make it-up, then all tests including the integration tests
make it-down               # stop and remove the integration services
DBDASH_NET=1 make test     # include a TLS handshake with a public server (system CAs)
make doc                   # regenerate doc/dbdash-schema.txt and doc/tags after changing
                           # the schema or the help
```

Everything these need is downloaded into `deps/` on first use (mini.nvim, StyLua,
luacheck and lua-language-server, pinned and checked by SHA-256): nothing is installed on
the system; the bootstrap needs only `git`, `curl` and `tar`. The recipes run Neovim
(`nvim -l scripts/*.lua`), so they work from PowerShell and cmd too; there, set variables
first, e.g. `$env:DBDASH_IT = 1; make test`.

### Integration tests

Integration tests run against the services in `tests/docker/compose.yaml`: Redis,
PostgreSQL, MySQL, MongoDB, Cassandra, SQL Server and nginx (HTTP/HTTPS), all official
images with the configs and test certificates (`tests/fixtures/`) mounted read-only. They
are skipped unless `DBDASH_IT=1` is set. With `DBDASH_IT=1` the examples test also runs
the examples that use these services (`example/databases/`, `example/connections/`) and
`example/connections/github.yaml` and `example/dashboards/multi_panel.yaml`, which call
the public GitHub API (network access needed).

**On one machine** with Docker (your user needs access to it, e.g. in the `docker` group,
or prefix the command with `sg docker -c "..."`):

```sh
make it                                               # start the services, run everything
DBDASH_IT=1 make test FILE=tests/db/test_postgres.lua # later: one file, services still up
make it-down                                          # when done
```

`COMPOSE` replaces the compose command, e.g.
`make it-up COMPOSE="podman compose -f tests/docker/compose.yaml"`.

**On two machines**: the containers run on a Docker host and the tests on another
machine (e.g. Windows without Docker). The services listen on these ports of the Docker
host:

| Service | Port | Service | Port |
|---|---|---|---|
| PostgreSQL | 15432 | Cassandra | 19042 |
| MySQL | 13306 | SQL Server | 11433 |
| Redis (plain / TLS) | 16379 / 16380 | nginx (HTTP / HTTPS) | 18080 / 18443 |
| MongoDB | 17017 | | |

They avoid the default ports so a local database is not hit by accident. The tests
always connect to `127.0.0.1` / `localhost` (the names the test certificates are issued
for), so forward these ports to the test machine over SSH instead of pointing the tests
at the host's address.

1. On the Docker host, start the services and leave them running:

   ```sh
   make it-up
   ```

2. On the test machine, open the tunnel and keep it running (`user@docker-host` is your
   SSH login on the Docker host):

   ```sh
   ssh -N -L 15432:127.0.0.1:15432 -L 13306:127.0.0.1:13306 -L 16379:127.0.0.1:16379 -L 16380:127.0.0.1:16380 -L 17017:127.0.0.1:17017 -L 19042:127.0.0.1:19042 -L 11433:127.0.0.1:11433 -L 18080:127.0.0.1:18080 -L 18443:127.0.0.1:18443 user@docker-host
   ```

3. On the test machine, in another terminal, set the environment variable `DBDASH_IT=1`
   and run `make test` (not `make it`, which would try to start Docker there):

   ```sh
   DBDASH_IT=1 make test
   ```

4. When done: stop the tunnel (Ctrl-C) and run `make it-down` on the Docker host.

## License

[MIT](LICENSE)
