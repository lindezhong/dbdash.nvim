# Development helpers. Runtime has no dependencies; mini.test is only used for tests.
NVIM ?= nvim
FILE ?=

.PHONY: deps test it fmt

deps: deps/mini.nvim

deps/mini.nvim:
	git clone --depth 1 --filter=blob:none https://github.com/echasnovski/mini.nvim $@

test: deps
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('tests.runner').run('$(FILE)')"

# Integration tests against real databases (see tests/docker/compose.yaml).
it: deps
	DBDASH_IT=1 $(MAKE) test

fmt:
	stylua lua tests plugin
