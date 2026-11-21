# Development helpers. Runtime has no dependencies; mini.test is only used for tests.
NVIM ?= nvim
FILE ?=

.PHONY: deps test it it-up it-down fmt

deps: deps/mini.nvim

deps/mini.nvim:
	git clone --depth 1 --filter=blob:none https://github.com/echasnovski/mini.nvim $@

# Tests use their own data/state/cache directories (not the user's passwords.json, shada...).
TEST_ENV = XDG_DATA_HOME=$(CURDIR)/deps/xdg/data XDG_STATE_HOME=$(CURDIR)/deps/xdg/state \
	XDG_CACHE_HOME=$(CURDIR)/deps/xdg/cache

test: deps
	$(TEST_ENV) $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('tests.runner').run('$(FILE)')"

# Integration tests against real databases (see tests/docker/compose.yaml).
COMPOSE ?= docker compose -f tests/docker/compose.yaml

it: deps it-up
	DBDASH_IT=1 $(MAKE) test

it-up:
	$(COMPOSE) up -d --wait

it-down:
	$(COMPOSE) down -v

fmt:
	stylua lua tests plugin
