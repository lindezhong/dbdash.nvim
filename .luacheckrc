-- luacheck (make lint): Neovim's LuaJIT, `vim` as a global.
std = "luajit"
globals = { "vim" }
max_line_length = 100
-- An implicit `self` and arguments named with a leading underscore may go unused.
self = false
ignore = { "212/_.*" }

files["tests/**/*.lua"] = { read_globals = { "MiniTest" } }

exclude_files = { "deps/**" }
