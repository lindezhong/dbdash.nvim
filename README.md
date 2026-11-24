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
  each with alternative styles (braille / block canvases, vertical bars, round pie, ...).
- **Several panels** per dashboard in a grid, each refreshing on its own interval.
  Dashboards that are not on screen pause and catch up when shown again.
- **Lua**: a `lua://` source whose query is Lua code, and `query.transform` to reshape any
  result with Lua before it is checked as rows (trusted configs only, as with `exrc`).
- **Query templates**: a Jinja2 subset with SQL-safe quoting filters, autoescape, macros
  and imports.
- **Thresholds**: color values (stat cards, table cells) and notify when a value crosses a level.
- **Arguments**: typed variables set from the command line, prompts or in the dashboard.
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

`setup()` is optional. Run `:helptags ALL` if your plugin manager does not build help tags.
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
dashboard; `●` marks running dashboards, `◐` paused ones (not on screen), `○` the others.

To try it without a database server, open any file in [`example/`](example): they all use
an in-memory SQLite database.

## Usage

| Command | Description |
| --- | --- |
| `:DbDashStart[!] {config} [name=value ...]` | Start a dashboard (`!` asks for every argument) |
| `:DbDashRestart` | Refresh now |
| `:DbDashStop [{config}]` | Stop a dashboard |
| `:DbDashList` / `:DbDashStatus` | Running dashboards / status and query history |
| `:DbDash` / `:DbDashClose` | Open / close the sidebar |
| `:DbDashShowVariables`, `:DbDashModifyVariable`, `:DbDashUpdateVariable {name} {value}`, `:DbDashResetVariables` | Show and change arguments |
| `:DbDashShowSQL` | Show the rendered query |
| `:DbDashExport[!] [csv\|tsv\|json\|markdown] [{file}]` | Export the result to a register or a file |
| `:DbDashStyle {type} {style}` | Re-render with another style, e.g. `:DbDashStyle line asciichart` |
| `:DbDashMksession[!] [{file}]` | Write a session (any `:mksession` restores dashboards) |

In a dashboard: `r` refresh, `a` modify an argument, `A` show arguments, `R` reset
arguments, `s` show the query, `e` export the result. Global mappings: `<leader>ds` start, `<leader>dr` refresh,
`<leader>dt` stop, `<leader>dl` list, `<leader>dd` sidebar.

Every key, the sidebar (width, position, directory, file globs, cursor line), where dashboards open,
the popup border and size, and the default interval, timeouts and row limit can be set
in `setup()`; see `:help dbdash-setup`. Colors use highlight groups (`:help
dbdash-highlights`), e.g. `DbDashSidebarDir` for sidebar directories.

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

A config file describes one dashboard: `database`, `query` and `show`, or `panels` and
`layout` for several charts. Each panel may set its own `database`; the top-level one is the
default for panels that do not. [`example/dbdash.schema.yaml`](example/dbdash.schema.yaml) is a
JSON Schema of the whole format; editors with yaml-language-server validate and complete a
config that starts with:

```yaml
# yaml-language-server: $schema=/path/to/dbdash.nvim/example/dbdash.schema.yaml
```

Examples, all runnable as they are:

| File | Shows |
| --- | --- |
| [`table.yaml`](example/table.yaml) | table columns, aliases, widths, styles |
| [`line.yaml`](example/line.yaml), [`area.yaml`](example/area.yaml), [`bar.yaml`](example/bar.yaml), [`histogram.yaml`](example/histogram.yaml), [`boxplot.yaml`](example/boxplot.yaml), [`heatmap.yaml`](example/heatmap.yaml), [`scatter.yaml`](example/scatter.yaml), [`bubble.yaml`](example/bubble.yaml), [`pie.yaml`](example/pie.yaml), [`stat.yaml`](example/stat.yaml), [`text.yaml`](example/text.yaml) | one chart type each |
| [`styles.yaml`](example/styles.yaml) | the alternative styles and canvases |
| [`multi_panel.yaml`](example/multi_panel.yaml) | several panels, grid layout, per-panel intervals |
| [`template_example.yaml`](example/template_example.yaml) | every argument type and the template syntax |
| [`macros.yaml`](example/macros.yaml) | macros, imports, autoescape |
| [`sqlite_file.yaml`](example/sqlite_file.yaml) | a SQLite file database |
| [`lua.yaml`](example/lua.yaml) | a `lua://` data source (Lua code, a command's output) |
| [`transform.yaml`](example/transform.yaml) | `query.transform` reshaping a query result with Lua |
| [`template_lua.yaml`](example/template_lua.yaml) | Lua in templates: `{% lua %}` blocks and an imported module ([`lua/helpers.lua`](example/lua/helpers.lua)) |
| [`http.yaml`](example/http.yaml) | an HTTPS API (GitHub releases) turned into rows by a transform (needs network) |

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
```

Passwords do not have to be in config files: use `${ENV_VAR}` in the URL,
`database.password_cmd` (e.g. `pass show db/app`), or
`~/.local/share/nvim/dbdash/passwords.json` (`:help dbdash-passwords`).

Common parameters: `tls=disable|require|pin|verify-ca|verify-full`,
`fingerprint=sha256:...` (for `pin`), `ca=bundle.pem`, `tls_host=name`,
`connect_timeout=10s`, `timeout=30s` (defaults changeable in `setup({ defaults })`).
Passwords are percent-decoded. Also accepted: `sqlite3://`, `postgresql://`, `mariadb://`,
`cql://`, `sqlserver://`. The query language
follows the database: SQL, CQL, one Redis command, or a JSON document for MongoDB.
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
time, OS, ...) `meta.<name>`, in templates and in Lua code alike. Templates can also run
Lua, in `query.sql` and `query.transform` alike:

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
`dbdash.query()` that wait without blocking the editor. dbdash asks before running a
config with Lua: one question per config, covering the config and the `.lua` files it imports,
asked again when any of them changes;
`setup({ lua = { confirm = false } })` or `lua.trusted_dirs` skip that. See `:help dbdash-lua`.

Every query goes the same way: query, then `query.transform` if there is one, then a check
that the result is rows. SQL results pass as they are; a `lua://` value or an HTTP response
usually needs the transform (`:help dbdash-transform`).

### HTTP

`http://` and `https://` URLs call an API; `query.sql` is a JSON request description:

```yaml
database:
  url: https://api.example.com/v1
query:
  sql: |
    {"method": "POST", "path": "search", "query": {"limit": {{ args.limit }}},
     "headers": {"Authorization": "Bearer {{ args.token }}"},
     "cookies": "session=abc", "body": {"q": "{{ args.keyword }}"}}
  transform: |
    local out = {}
    for _, it in ipairs(rs.data.items) do out[#out + 1] = { name = it.name, n = it.count } end
    return out
```

The transform gets the decoded JSON as `rs` and `response` (status, headers, body). A JSON
list of objects or `{"columns": [...], "rows": [...]}` shows without a transform; every
result must end up in one of these row shapes (`:help dbdash-result`).
`cookies` takes curl's `-b` forms (`"a=1; b=2"` or a Netscape cookie file); cookies the
server sets are kept in memory for the dashboard and sent on the next refresh, without
touching the config. `https` verifies certificates by default. See `:help dbdash-http`.

## Coming from vim-dashboard

No Python, venv or pynvim any more. Commands are renamed from `:Dashboard…` to
`:DbDash…` one to one (`:Dashboard` → `:DbDash`, `:DashboardStart` → `:DbDashStart`,
`:DashboardMksession` → `:DbDashMksession`, ...); the buffer and sidebar keys are the
same. Existing configs mostly work. Differences:

- Arguments use `name:`; the old `key:` is rejected with a hint.
- Fields only meaningful for matplotlib are ignored.
- `sql_id` quotes with the database's identifier quotes instead of always backticks,
  `sql_in` of an empty list gives `(NULL)`, and booleans become SQL literals rather than
  `True` / `False`.

## Limitations

- Each refresh opens a new connection; there is no connection pool.
- No certificate revocation checks (CRL / OCSP); TLS 1.0/1.1, renegotiation and session
  resumption are not supported.
- The cryptography is pure Lua and not constant-time.
- SQL Server `encrypt=strict` (TDS 8) is not covered by the integration tests.
- Oracle is not supported.

## Development

```sh
make test                  # unit, golden and UI tests (clones mini.nvim into deps/)
make test FILE=tests/yaml/test_parse.lua
UPDATE_GOLDEN=1 make test  # regenerate render reference outputs
make it-up                 # start the integration services (docker compose, waits until ready)
make it                    # make it-up, then all tests including the integration tests
make it-down               # stop and remove the integration services
DBDASH_NET=1 make test     # include a TLS handshake with a public server (system CAs)
make fmt                   # format with stylua
```

### Integration tests

Integration tests run against the services in `tests/docker/compose.yaml`: Redis,
PostgreSQL, MySQL, MongoDB, Cassandra, SQL Server and nginx (HTTP/HTTPS), all official
images with the configs and test certificates (`tests/fixtures/`) mounted read-only. They
are skipped unless `DBDASH_IT=1` is set. With `DBDASH_IT=1` the examples test also runs
`example/http.yaml`, which calls the public GitHub API (network access needed).

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
