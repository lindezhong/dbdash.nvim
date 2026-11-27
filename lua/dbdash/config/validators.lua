-- The modules with rules for parts of a config: each exports M.validators, a list of
-- { field = <part>, validate = fun(value, ctx, path) } that config.lua runs on that part
-- when a config loads (ctx:fail(path, msg, ...) reports a problem with its line).
--   database  a database ({ type, url, options, password_cmd }), top-level or a panel's
--   style     the rules of a style sheet (css/parser.lua), top-level or a panel's
return { "dbdash.db", "dbdash.render.registry" }
