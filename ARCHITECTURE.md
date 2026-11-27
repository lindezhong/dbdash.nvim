# Architecture

How dbdash.nvim is put together: where data comes from, how it reaches the screen, and
which module owns what. User documentation is `:help dbdash`; this file is for people
changing the code. Diagrams name modules under `lua/dbdash/`.

## Overview

A dashboard is a YAML config. Loading it checks everything that can be known before
running. Each panel then runs its data source; every result goes through the same
consumer (`query.transform`, the rows check) into the dashboard's model, which writes what
is shown into the dashboard's document (a DOM). A view draws that document the way a
browser renders a page: style, layout, paint, composite, into a Neovim buffer.

```
config file ─► config.load ─► dashboard (model) ─► db.run ─► results ─► consumer
                                   │                                       │
                                   │ commit: the display state into the DOM ◄┘
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
- The model never requires a view. It tells the rest through events
  (`dashboard/events.lua`) and through its document (a change asks its view for a frame).
- Hooks the entry module wires for lower layers: the trust prompt's View float
  (`trust.viewer`) and the dashboard keys' actions (the `action` event → `commands`).

## Startup and configuration

```
:DbDashStart file.yaml / require("dbdash").start()
  └ view/dashboard.start                         the UI side
      ├ dashboard.prepare(path, tokens)          dashboard/lifecycle.lua
      │   ├ config.load                          the only reader of config files
      │   │   ├ yaml.parse_file                  every value knows its line
      │   │   ├ structure and types              (config.lua)
      │   │   └ validators                       rules of other modules (config/validators.lua)
      │   │       db                database: URL parameters, the driver's options
      │   │       render.registry   style: renderer, canvas and palette names
      │   │       → ctx:fail(path, msg) reports the line
      │   ├ trust.check                          Lua code and curl -c: ask first
      │   └ the command line's arguments
      ├ view/args_ui.ask_all                     missing required arguments
      ├ dashboard.create(path, cfg, state, restored)
      │   panels, the document (dashboard/document.lua), the session's argument values,
      │   the clock and every panel's source; event `started`
      └ attach: the buffer, Document.on_update → a frame, the key actions, countdowns
```

Only what depends on templates is checked when it runs: the rendered curl command,
OpenAPI document or SQL.

## Data sources

Every data source is a driver (`db/init.lua`): it has `connect` (a database, queried) or
`produce` (a source that sends data), the options it reads (`options`, checked by
`db/options.lua`) and the name of its template dialect (`template/dialect.lua`).

```
db.run(url, query, opts, on_result, on_end) → handle { stop, stats, status }
  common: ${NAME} → driver → db.validate (URL, options) → parse_url
          cancel token, on_stop cleanups, error wrapping, stats, back to the main loop
  produce(info, query, ctx)       exec, luastream, webhook: ctx.emit(value, vars),
                                  ctx.writer(delimiter) cut into items, ctx.set_status,
                                  ctx.on_stop; the run ends when it returns
  connect (pull loop)             sqlite, postgres, mysql, mssql, cassandra, mongodb, redis,
                                  http, lua: on every ctx.wait_tick(), query() renders the
                                  query anew and db.query runs it (timeouts, cancelling on
                                  the server); its result or error goes on, the loop goes on
  on_result(err, value, vars, tag)  a result (one may hold many rows), or a query's error
```

`db.query` (the Lua API, `dbdash.query` in Lua code) runs one query; the pull loop uses it
for each of its queries.

## Scheduling

One clock per dashboard (`dashboard/timer.lua`) keeps every panel's next tick
(`show.interval`) and the top-level interval's (a tick for every panel) on one uv timer.

```
wake: the deadlines that passed
  top-level due   → every panel (except one backing off: its retry time stays)
  a panel's own   → that panel
  both at once    → one tick (deadlines within 1% of the interval, at least 50 ms)
  each due panel: Panel:on_tick(), and its count restarts from now; a panel whose interval
  is the top-level one or longer only ever ticks with the others
paused (hidden): only show.refresh_hidden panels tick; shown again, what came due ticks
```

`Panel:on_tick()` gives a waiting pull loop its tick (it queries); a tick while the query
runs is skipped (history). A source that sends data never waits for ticks; for it a tick
only draws what came. User actions (`r`, changed arguments) restart the panel's run at once.

Failures of a source that waits for ticks back off: after the n-th in a row the next query
waits interval × 2^(n-1), at most interval × `errors.backoff`; the first success returns
to the interval.

## Results

```
on_result → Panel:on_result: queued (setup push.max_queue, unlimited by default)
          → Panel:consume: one task, in order, one result at a time
              a query's result: query.transform (rendered with the query), rows check
              an item: query.transform rendered for it (or the item as JSON rows)
          → Panel:settle: the run's record (meta.prev), history, the result or the error
              (event `error`), stat values, thresholds (event `threshold`)
          → commit: a query's result at once; an item at the panel's next tick
```

`dbdash.run(args)` in Lua code runs the panel's pipeline again with other arguments: a
query panel queries once, a push panel takes the current item again; nothing is settled.

## Drawing

The model commits: `Dashboard:commit()` brings the document up to date
(`dashboard/document.lua`: titles, errors, argument lines, each chart's content through
`render/content`). Only changes mark nodes dirty; a document that gets something to
update asks its view for a frame (`Document.on_update`).

```
view/dashboard.request_render  one frame for every request within 20 ms; none while hidden
  frame: css/style.restyle          cascade, styles shared by key, dirty subtrees only
         layout/view.reflow         grid tracks, panel sizes, a layout cache
           layout/replaced.raster   a chart is a replaced element: render.render draws it
         paint.view                 a display list (render/box: borders and padding)
         compositor.compose         layers into lines
         view/buffer.draw           changed lines and extmarks
  the status line (update_status): countdowns, running / listening / ended, errors
```

## Events

`dashboard/events.lua` is the emitter of the model; listeners get the dashboard first.

| Event | When | Listeners |
|---|---|---|
| `started` / `stopped` | a dashboard runs / stopped | sidebar; the view closes its buffer |
| `paused` / `resumed` | hidden / shown again | sidebar; the view's countdowns and catch-up frame |
| `state` | what the status line shows changed | view (status line) |
| `error` | an error of a result or a source | view/notifier (`errors.notify`) |
| `threshold` | a value rose to a step that notifies | view/notifier |
| `action` | a dashboard key's event reached the document's root | commands (wired in init.lua) |

## How it compares to a browser

| Browser | dbdash |
|---|---|
| task queue | a panel's queue of results |
| `setInterval` + `fetch` | the clock + a database's pull loop |
| WebSocket `onmessage` | a push source's producer |
| JS event handler | the consumer (transform, settle) |
| JS variables | the model (history, prev, store, values) |
| `requestAnimationFrame` writing the DOM | commit (a push panel's items at its next tick) |
| update the rendering (only what is dirty) | the view's frame |
| hidden tab: no rendering, slower timers | hidden dashboard: no frames, only refresh_hidden ticks |

## Interfaces

| Interface | Defined in | Implemented by |
|---|---|---|
| `dbdash.db.Driver`, `Connection`, `StreamCtx` | `db/types.lua` (base: `db/driver.lua`) | `db/drivers/*` |
| a config part's rules (`M.validators`) | `config/types.lua` (listed in `config/validators.lua`) | `db`, `render/registry` |
| chart renderers, canvases, ticks, palettes, frames | `render/types.lua` (checked by `render/registry.lua`) | `render/charts/*`, `render/{canvas,ticks,palette,frame}/*` |
| `dbdash.render.Output` (lines and highlights) | `render/types.lua` | every renderer |

## Directory map

```
lua/dbdash/
  init.lua, commands.lua   setup, mappings, the Lua API; commands and key actions
  view/                    dashboard (frames, starting), buffer, sidebar, popups, notifier,
                           trust's View float, argument prompts
  dashboard/               the model: dashboards, panels, runs, clock, document, events
  config.lua, config/      loading configs; the validator list
  options.lua, session.lua setup's options; argument values in sessions
  trust.lua, metadata.lua  trust records; meta for templates and Lua
  layout/, paint/          grid and panels; display lists
  render/, compositor/     charts, their content and parts, the registry; layers into lines
  css/, dom/               style system; documents and nodes
  db/                      db.run, drivers, results, the Lua sandbox of queries
  template/                the Jinja2 engine and SQL dialects
  net/, crypto/, yaml/     sockets, TLS, HTTP, OpenAPI; cryptography; YAML
  util/                    errors, JSON, UTF-8, numbers, time, shell, URLs, events, ...
```
