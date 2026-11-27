-- The events of the running dashboards (ARCHITECTURE.md#events), for whoever follows all of
-- them (the sidebar, the notifier, the views). A dashboard's own events are on d.events
-- (dashboard/dashboard.lua, dashboard/panel.lua).
--   dashboard:started(d)        created and about to run (listen to d.events now)
--   dashboard:stopped(d, o)     stopped (o.keep_buffer: its view keeps the buffer)
--   dashboard:error(path, err)  a config could not start
--   action(d, action, ev)       a dashboard key's event reached its document's root
return require("dbdash.util.emitter").new()
