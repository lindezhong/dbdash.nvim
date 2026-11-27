-- luacheck (make lint): Neovim's LuaJIT, `vim` as a global.
std = "luajit"
globals = { "vim" }
-- Code width is StyLua's (column_width 100: it wraps what can be wrapped; a long string
-- literal stays whole, to be found by search). Comments, LuaLS annotations too, fit in 100.
max_code_line_length = false
max_string_line_length = false
max_comment_line_length = 100
-- An implicit `self` and arguments named with a leading underscore may go unused.
self = false
-- An if branch may be empty when its comment says why the case needs nothing (protocol
-- messages to skip: every case is listed).
ignore = { "212/_.*", "542" }

files["tests/**/*.lua"] = { read_globals = { "MiniTest" } }

exclude_files = { "deps/**" }
