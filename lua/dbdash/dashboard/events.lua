-- The events of dashboards (ARCHITECTURE.md#events): the model emits them, views and the
-- notifier listen. Listeners get the dashboard first, then the event's values.
--   started(d), stopped(d, o)     a dashboard runs / stopped (o.keep_buffer)
--   paused(d), resumed(d)         hidden / shown again
--   state(d, p?)                  what the status line shows changed (running, retrying...)
--   error(d, p, err, o)           an error to tell (o.changed: not the panel's last one;
--                                 o.always: told whatever errors.notify says)
--   threshold(d, p, crossed)      a value rose to a threshold step that notifies
return require("dbdash.util.emitter").new()
