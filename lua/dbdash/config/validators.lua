-- The modules with rules for parts of a config (config/types.lua): each exports
-- M.validators, a list of { field = <part>, validate = fun(value, ctx, path) } that
-- config.lua runs on that part when a config loads, in this order (a rule may return the
-- value normalized for the next ones). ctx:fail(path, msg, ...) reports a problem with its
-- line. The parts:
--   database   { type?, url, options, password_cmd } as written, top-level or a panel's
--   arg, args  an argument spec; the list of a section (path: the list)
--   show       a panel's show section (defaults applied)
--   panel      a panel's config (path: its prefix, "" or "panels[i].")
--   style      a style sheet as written (selector -> properties), top-level or a panel's
--   dashboard  the whole config
return {
  "dbdash.css",
  "dbdash.args",
  "dbdash.db",
  "dbdash.render.registry",
  "dbdash.render.thresholds",
  "dbdash.layout.grid",
  "dbdash.dashboard.timer",
}
