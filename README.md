# dbdash.nvim

Database dashboards inside Neovim: periodically run a query and render the result as a
table or a terminal chart. Pure Lua, Neovim 0.12+, no external dependencies
(SQLite is accessed through LuaJIT FFI and the system `libsqlite3`).

Status: work in progress.

## Development

```sh
make test            # unit + golden tests (clones mini.nvim into deps/ on first run)
make test FILE=tests/test_smoke.lua
UPDATE_GOLDEN=1 make test
make it              # integration tests, requires docker (tests/docker/compose.yaml)
```
