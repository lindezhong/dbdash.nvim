# Architecture

How dbdash.nvim is put together: where data comes from, how it reaches the screen, and
which module owns what. User documentation is `:help dbdash`; this file is for people
changing the code. Diagrams name modules under `lua/dbdash/`.

## Overview

A dashboard is a YAML config. Loading it checks everything that can be known before
running. Each panel then runs its data source; every result goes through the same
consumer (`query.transform`, the rows check) into the panel's state, which holds all
there is to know about the panel (its status and its data) and is sent whole to whoever
listens. The dashboard sums its panels' states. Commit writes what is shown into the
dashboard's document (a DOM); a view draws that document the way a browser renders a
page: style, layout, paint, composite, into a Neovim buffer.

```
config file ─► config.load ─► dashboard (model) ─► db.run (producer) ─► results ─► consumer
                                   │  clock: panel:tick                                │
                                   │  Panel.state ◄── the panel, its one writer ◄──────┘
                                   │    panel:state ─► history, thresholds, notifier, commit
                                   │  Dashboard.state: the sum of its panels' ─► sidebar
                                   │  commit: the display state into the DOM
                                   ▼
buffer ◄─ compositor ◄─ paint ◄─ layout ◄─ css ◄─ document (dirty) ◄─ frame (view)
```

## Layers

A module requires modules of its own layer or below, never above, and no module requires
itself through others. `tests/test_layers.lua` checks both.

```
UI and entry   init · commands · view/* · events (DOM events) · inspect · health
application    dashboard/* · config (+ config/validators) · trust · metadata
               · options · session · export
drawing        layout · paint · render · compositor        (one way: layout uses paint,
                                                             paint uses render)
components     args · template · db · css · dom
protocols      net (+ tls) · crypto · yaml
utilities      util/*
```

Rules that keep it so:

- Lower layers do not read setup's options. `options.set()` hands them what they use:
  `db/defaults` (timeouts, max rows, the longest push item), the user style sheet
  (`css.user_style`), the tick algorithm and user implementations (`render.registry`).
- The model never requires a view. It tells the rest through events (each dashboard's
  `d.events`, and `dashboard/events.lua` for all of them) and through its document (a
  change asks its view for a frame).
- Hooks the entry module wires for lower layers: the trust prompt's View float
  (`trust.viewer`), the report of a failing event listener (`util/emitter.on_error` →
  `view/notifier`) and the dashboard keys' actions (the `action` event → `commands`).
- `plugin/dbdash.lua` forwards Neovim's events to the view: reading a dbdash:// buffer
  (`on_read`), visibility (`update_visibility`), closed windows, resizes and exiting
  (`on_exit`); a new colorscheme only makes the highlight groups again (`css/hl.lua`).
  The view calls the model when it is concerned (`d:pause()`, `d:resume()`,
  `dashboard.stop`).

## Startup and configuration

```
:DbDashStart file.yaml / require("dbdash").start()
  └ view/dashboard.start                         the UI side
      ├ dashboard.prepare(path, tokens)          dashboard/init.lua
      │   ├ config.load                          the only reader of config files
      │   │   ├ yaml.parse_file                  every value knows its line
      │   │   ├ structure and types              (config.lua: fields, defaults, panels)
      │   │   └ validators                       the rules of the modules (config/validators.lua)
      │   │       css                style: the sheet parses (gives its rules)
      │   │       args               arg, args: names, types, each name once
      │   │       db                 database: the driver (type or URL), the URL's
      │   │                          variables and parameters, password_cmd, the options
      │   │       render.registry    show: the chart type; style: renderer, canvas, palette
      │   │       render.thresholds  show: thresholds
      │   │       layout.grid        dashboard: the panels can be placed
      │   │       dashboard.timer    show, panel, dashboard: intervals, refresh_hidden
      │   │       → ctx:fail(path, msg) reports the line
      │   ├ trust.check                          Lua code and curl -c: ask first
      │   │                                      (unless trust.required says no)
      │   └ the command line's arguments
      ├ view/args_ui.ask_all                     missing required arguments
      ├ dashboard.create(path, cfg, state, restored)
      │   Dashboard.new: its events, clock, panels, document (dashboard/document.lua) and
      │   subscribers (history, track, thresholds, commit); the session's argument values;
      │   event `dashboard:started`; Dashboard:start: commit, the clock, every source
      └ attach: the buffer, Document.on_update → a frame, the key actions, countdowns
```

A config without `panels:` is a dashboard of one panel: once loaded, a config is always
its list of panels (`cfg.panels`), and nothing after loading asks how it was written.

Only what depends on templates is checked when it runs: the rendered curl command,
OpenAPI document or SQL.

## Data sources

Every data source is a driver (`db/types.lua`): it has `connect` (a database, queried) or
`produce` (a source that sends data), the options it reads (`options`, checked by
`db/options.lua`) and the name of its template dialect (`template/dialect.lua`). A
database's producer is the same for all of them (`db/driver.lua`).

```
db.run(url, query, opts, on_result, on_end) → handle { stop, report, stats, status }
  common: ${NAME} → driver → db.validate (URL, options) → parse_url
          cancel token, on_stop cleanups, error wrapping, stats, back to the main loop;
          without query.transform an item becomes rows (JSON rows, or one record)
  produce(info, query, ctx)       exec, luastream, webhook: ctx.emit(value, vars),
                                  ctx.writer(delimiter) cut into items, ctx.set_status,
                                  ctx.on_stop; the run ends when it returns
  connect: db/driver.producer     sqlite, postgres, mysql, mssql, cassandra, mongodb, redis,
                                  http, lua; the loop:
    ctx.wait_tick(not_before, failures)   the next tick (opts.wait_tick: the panel's);
                                          earlier than not_before: it passes
    query()                               renders the query anew: sql, tag, options
    driver.execute: a Query, connect → execute → close (timeouts; cancelling stops it on
                    the server: stop waiting, cancel on the server, close)
    ctx.emit(rs, tag) / ctx.fail(err, tag), then wait for handle:report(ok) (the consumer)
    failures in a row: not_before = now + interval × min(2^(n-1), errors.backoff)
  on_result(err, value, vars, tag)  a result (one may hold many rows), or a query's error
```

`db.query` (the Lua API, `dbdash.query` in Lua code) is a run of one tick: its first
result.

`webhook://` is a producer like the others; the HTTP side is the network layer's:
`net/http_server` (connections, limits, Host and Origin checks, problem responses) and
`net/openapi` (`Api:handle`: the operation, its security and parameters, the body's
items by media type, validation, the response).

## State

A panel's state (`Panel.state`) is all there is to know about the panel at this moment,
in one table: who it is, what it is doing and its data. The panel is its only writer.
Every change (a query starts or ends, a result, an error, the dashboard hidden or shown,
its source's state) updates it and tells `panel:state(p, state, changed)` on `d.events`,
`changed` naming the fields that changed. Listeners read the state they are given, never
other fields of the panel.

```
Panel.state
  identity  path      the config file
            id        the panel's `id`, else "panel<N>"
            index     its place in the panels
            title     as shown: show.title, else "Panel N"
  status    fetching  it obtains data: a database is ticked (the dashboard is shown, or
                      show.refresh_hidden); a source that sends data is alive (starting,
                      running, listening)
            drawing   its results are committed and drawn: the dashboard is shown (always
                      with setup dashboard.pause_hidden = false)
            activity  "idle" | "querying" | "retrying"
            source    what a source that sends data says ("listening 127.0.0.1:8765",
                      "ended", "failed"); nil for a database
            next_at   its next tick (the countdown)
  data      result    the current result
            error     the current error
            prev      the result before it (meta.prev)
            run       the record of the run that made the data
            stream    a source that sends data: received, processed, dropped
```

A dashboard's state (`Dashboard.state`) sums its panels'; the dashboard is its only
writer. It follows its panels' `panel:state` and, when what it sums changes, tells
`dashboard:state(d, state, changed)` on `dashboard/events.lua`. A new result changes none
of it: what follows dashboards (the sidebar) is not told about every result.

```
Dashboard.state
  path      the config file
  title     the dashboard's title
  running   started (false: told once more when it stops)
  visible   a window of the current tab page shows it
  fetching  "all" | "some" | "none": its panels' state.fetching
  panels    { [id] = Panel.state }
```

```
the panel: its one writer
  Panel.state ─ panel:state(p, state, changed) ─┬─ the clock      changed.fetching: ticks or not
    (d.events)                                  ├─ history        changed.result / error
                                                ├─ track, thresholds   changed.result
                                                ├─ commit         into the document while drawing
                                                ├─ view/notifier  changed.error (errors.notify)
                                                └─ the dashboard  sums its panels
the dashboard: the sum
  Dashboard.state ─ dashboard:state(d, state, changed) ─┬─ sidebar   ● all fetching, ◐ some,
    (dashboard/events.lua)                              │            ○ none; ◌ not running
                                                        ├─ :DbDashStatus  d.state, each panel's
                                                        └─ :DbDashList    d.state
```

## Scheduling

`show.interval` is a panel's period: it shows new data at most once per period. One clock
per dashboard (`dashboard/timer.lua`) keeps every panel's next tick and the top-level
interval's (a tick for every panel) on one uv timer, and tells each tick as `panel:tick`.

```
wake: the deadlines that passed
  top-level due   → every panel (except one backing off: its retry time stays)
  a panel's own   → that panel
  both at once    → one tick (deadlines within 1% of the interval, at least 50 ms)
  each due panel: panel:tick, and its count restarts from now; a panel whose interval is
  the top-level one or longer only ever ticks with the others
panel:state       only panels whose state.fetching is true tick (changed.fetching:
                  hidden, shown again); one that starts fetching ticks now if it came due
dashboard:args    every count starts again (and every panel's run)
```

`panel:tick` listeners: the panel (a database's loop waiting in `ctx.wait_tick` queries; a
tick while the query runs is skipped, `panel:skipped`) and commit (a new period). A source
that sends data never waits for ticks.

A hidden dashboard (setup `dashboard.pause_hidden`) spends nothing on what is shown: each
panel sets its state (`dashboard:hidden` / `shown`): `drawing` false, and `fetching`
false for a database (unless `show.refresh_hidden`), so it gets no tick and is not
queried; nothing is committed and no frame is drawn. A source that sends data cannot be
paused without losing data: it keeps `fetching`, its items are still received and
processed (transform, history, thresholds and errors notify), and the latest is committed
when the dashboard is shown again.

User actions (`r`, changed arguments) restart the panel's run at once. Each run has a number (`Panel.gen`): ticks and results of an older
run are dropped.

Failures of a database back off in its loop (`db/driver.lua`): after the n-th in a row the
next query waits interval × 2^(n-1), at most interval × `errors.backoff`; the panel keeps
that time as its next deadline (countdown, `:DbDashStatus`); the first success returns to
the interval.

## Results

```
on_result → Panel:on_result: queued (setup push.max_queue, unlimited by default)
          → Panel:consume: one task, in order, one result at a time
              a query's result: query.transform (rendered with the query), rows check
              an item: query.transform rendered for it (or the item as JSON rows)
          → Panel:settle: the run's record, then the state: its result or its error, its
              run and prev (`panel:state`, changed.result / changed.error);
              handle:report(ok) tells the source how it went
  panel:state listeners, in order:
              history (dashboard/history.lua), stat values (track.lua), thresholds
              (thresholds.lua: `panel:threshold`), view/notifier (errors.notify), commit
              (commit.lua), the dashboard (its sum)
```

A panel's templates (query.sql, query.transform, an item's transform, show.description)
are rendered by its run (`Run:render`), the one place their options are made (the
arguments, `meta`, the Lua globals, set_arg); the dashboard's description by
`Run.dashboard_opts` (the shared arguments, the dashboard's `meta`).

`dbdash.run(args)` in Lua code runs the panel's pipeline again with other arguments: a
query panel queries once, a push panel takes the current item again; nothing is settled.

A source that sends data does not back off: a failed item is that item only (its report
is ignored), and the next one replaces the error.

## Errors

Every error is a `dbdash.Error` (`util/error.lua`): a phase (config, template, connect,
tls, auth, query, transform, timeout, cancelled, ...), a message and, where they apply,
the driver, a code, more lines, the file and line. Raised with `errors.raise(phase,
message, extra)`; what is raised elsewhere (a string from Lua) becomes one with
`errors.wrap`. All read the same way: `[<driver> ]<phase> error: [<file>:<line>:
]<message>[ [code]]`. Internal signals (an HTTP rejection inside the server, a stopped
Lua guard) are tables of their own and never reach the user as such.

## Drawing

The model commits (`dashboard/commit.lua`), the one writer of what is shown: it writes it
into the document (built by `dashboard/document.lua`): each panel's title (`show.title`;
without one, "Panel N" when the dashboard has more than one panel, none when it has
one), errors, argument lines, each chart's content (built here only, through
`render/content`; renderers read it with `content.root`), and the status as element data
(`Node:set_data`: running, a source's state, the next tick). A panel's results are
committed at most once per period: the first of a period at once (a database's query of
the tick), later ones at the next `panel:tick`; a tick with nothing pending writes
nothing; a hidden dashboard commits nothing, and what waited is committed when it is
shown. Only changes mark nodes dirty; a document that gets something to update asks its
view for a frame (`Document.on_update`). Whether a frame has something to draw is the
document's version against the last frame's (`Document:needs_frame`): a style query
(`css/style.get`, as getComputedStyle) may restyle early, the frame still draws.

Every dashboard is drawn the same way: a header (the dashboard's title and ⓘ) and a grid
of panels, one panel being a grid of one. A panel's box holds, in order:

```
title line   title · ⓘ · its status slot     (when any of them can show; on a border:
                                             the top line)
error line   ✗ the error, wrapped, never cut
subtitle · argument line · the chart          (render.render draws the chart only)
```

```
view/dashboard.request_render  one frame for every request within 20 ms; none while hidden
  only element data changed: the status line, nothing else
  frame: css/style.restyle          cascade, styles shared by key, dirty subtrees only
         layout/view.reflow         the header and the grid: tracks, panel sizes, a
                                    layout cache
           layout/replaced.raster   a chart is a replaced element: render.render draws it
         paint.view                 layers (paint/box: borders, padding) and each
                                    panel's status slot
         compositor.compose         layers into lines
         view/buffer.draw           changed lines and extmarks
         update_status              one mark per panel on its title line (and the
                                    header's countdown), placed by countdown_position:
                                    right_align / eol in the free cells after the title
                                    and ⓘ (cut with "…", left out without room),
                                    overlay at the line's start
```

## User messages

Everything the plugin tells the user goes through `view/notifier` (`error`, `warn`,
`info`; "dbdash: " before each): command errors, setup errors, trust results, exports,
dashboard errors by `errors.notify`, thresholds that notify, failing event listeners
(through `util/emitter.on_error`). What a command prints as its output (`:DbDashList`) is
echoed.

## Events

Each dashboard tells on its own emitter, `d.events` (`util/emitter.lua`: listeners run at
once, in order); listeners of panel events get the panel first.

| Event | When | Listeners |
|---|---|---|
| `panel:tick` | the clock: a panel's deadline, the top-level one, catching up | the panel (its database's loop), commit |
| `panel:state` | the panel's state changed (`Panel.state`, sent whole; `changed`: which fields): a result, an error, querying, retrying, its source's state, fetching, drawing | the clock, history, track, thresholds, view/notifier, commit, the dashboard (its sum) |
| `panel:skipped` / `panel:cancelled` | a tick while the query ran / a run cancelled | history |
| `panel:threshold` | a value rose to a step that notifies | view/notifier |
| `dashboard:args` | the arguments changed | the clock, every panel (restart), commit |
| `dashboard:hidden` / `shown` | no window shows it / shown again | every panel (its state: fetching, drawing), commit (what waited) |

For whoever follows every dashboard, `dashboard/events.lua`:

| Event | When | Listeners |
|---|---|---|
| `dashboard:started` / `stopped` | created / stopped | notifier (it listens to its `d.events`); the view closes its buffer |
| `dashboard:state` | what a dashboard sums changed (`Dashboard.state`: running, visible, fetching) | sidebar |
| `dashboard:error` | a config could not start | view/notifier |
| `action` | a dashboard key's event reached the document's root | commands (wired in init.lua) |

The view listens to no data event: what it shows comes from the document. Events that
carry state send it whole (`panel:state`, `dashboard:state`); `panel:tick`,
`panel:skipped`, `panel:cancelled` and `panel:threshold` tell that something happened.

## How it compares to a browser

| Browser | dbdash |
|---|---|
| task queue | a panel's queue of results |
| `setInterval` + `fetch` | the clock + a database's pull loop |
| WebSocket `onmessage` | a push source's producer |
| JS event handler | the consumer (transform, settle) |
| JS variables | the model (history, prev, store, values) |
| `requestAnimationFrame` writing the DOM | commit (at most once per panel period) |
| update the rendering (only what is dirty) | the view's frame |
| hidden tab: no rendering, slower timers | hidden dashboard: no frames, no commits, only refresh_hidden ticks; push sources keep receiving |

## Interfaces

| Interface | Defined in | Implemented by |
|---|---|---|
| `dbdash.db.Driver`, `Connection`, `StreamCtx` | `db/types.lua` (base: `db/driver.lua`) | `db/drivers/*` |
| a config part's rules (`M.validators`) | `config/types.lua` (listed in `config/validators.lua`) | `css`, `args`, `db`, `render/registry`, `render/thresholds`, `layout/grid`, `dashboard/timer` |
| chart renderers, canvases, ticks, palettes, frames | `render/types.lua` (checked by `render/registry.lua`) | `render/charts/*`, `render/{canvas,ticks,palette,frame}/*` |
| `dbdash.render.Output` (lines and highlights): the chart only, never its title | `render/types.lua` | every renderer |
| a chart's content (DOM) | `render/content` (`build` by commit, `root` for renderers) | `render/content/*`; read by table and text renderers |
| `dbdash.Error` | `util/error.lua` | every error shown to the user |
| a run of `db.run` (`dbdash.db.RunHandle`) | `db/init.lua` | used by `dashboard/panel.lua` |

## Directory map

```
lua/dbdash/
  init.lua, commands.lua   setup, mappings, the Lua API; commands and key actions
  view/                    dashboard (frames, starting), buffer, sidebar, popups, notifier,
                           trust's View float, argument prompts
  dashboard/               the model: the running dashboards (init), Dashboard, Panel, Run,
                           clock (timer), document, commit, history, track, thresholds,
                           events
  config.lua, config/      loading configs; the validator list and its interface
  options.lua, session.lua setup's options; argument values in sessions
  trust.lua, metadata.lua  trust records; meta for templates and Lua
  layout/, paint/          grid and panels; display lists and boxes (borders, padding)
  render/, compositor/     charts, their content and parts, the registry, the interfaces;
                           layers into lines
  css/, dom/               style system; documents and nodes
  db/                      db.run, the drivers' interface and base (types, driver), drivers,
                           results, the Lua of queries (lua_env)
  template/                the Jinja2 engine and SQL dialects
  net/, crypto/, yaml/     sockets, TLS, HTTP, OpenAPI; cryptography; YAML
  util/                    errors, JSON, UTF-8, numbers, time, shell, URLs, events, the Lua
                           sandbox (guard and helpers: Lua of queries and of templates), ...
```
