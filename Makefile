# Development helpers. Runtime has no dependencies; mini.test is only used for tests, and
# the formatter, linter and type checker (scripts/tools.lua) only by lint and fmt. All of
# them go into deps/: nothing is installed on the system.
NVIM ?= nvim
FILE ?=

.PHONY: deps tools test lint it it-up it-down fmt doc

deps: deps/mini.nvim tools

# StyLua, luacheck and lua-language-server at pinned versions (checksums verified).
tools:
	$(NVIM) -l scripts/deps.lua

deps/mini.nvim:
	git clone --depth 1 --filter=blob:none https://github.com/echasnovski/mini.nvim $@

# A full run lints first; `make test FILE=...` (one file) does not. The tests run with their
# own data/state/cache directories (scripts/test.lua).
test: deps $(if $(FILE),,lint)
	$(NVIM) -l scripts/test.lua $(FILE)

# Integration tests against real databases (see tests/docker/compose.yaml).
COMPOSE ?= docker compose -f tests/docker/compose.yaml

it: deps it-up $(if $(FILE),,lint)
	$(NVIM) -l scripts/test.lua --it $(FILE)

it-up:
	$(COMPOSE) up -d --wait

it-down:
	$(COMPOSE) down -v

# StyLua --check, luacheck and lua-language-server (scripts/lint.lua).
lint: deps
	$(NVIM) -l scripts/lint.lua

fmt: deps
	$(NVIM) -l scripts/lint.lua fmt

# doc/dbdash-schema.txt (:help dbdash-schema) from example/dbdash.schema.yaml, and
# doc/tags (committed, so :help works right after any install); make test fails while
# either is out of date.
doc:
	$(NVIM) --headless -u NONE -l scripts/schema_doc.lua
	$(NVIM) --headless -u NONE -c "helptags doc" -c q
