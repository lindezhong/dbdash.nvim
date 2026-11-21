-- Checks shared by the per-database health modules (:checkhealth dbdash.<database>).
local M = {}

---The driver module loads.
---@param name string driver name (dbdash.db.drivers.<name>)
function M.driver(name)
  local ok, err = pcall(require, "dbdash.db.drivers." .. name)
  if ok then
    vim.health.ok("driver loads")
  else
    vim.health.error("driver does not load: " .. tostring(err))
  end
  return ok
end

---The system CA store, needed for tls=verify-ca / verify-full without ?ca=.
function M.ca_store()
  vim.health.start("TLS certificates (tls=verify-ca / verify-full)")
  local ok, store = pcall(require("dbdash.net.tls.truststore").system)
  if ok then
    vim.health.ok(("system CA store: %d certificates from %s"):format(#store.certs, store.source))
    if jit.os == "Windows" then
      vim.health.info(
        "Windows installs many root certificates only when a program first needs them; if "
          .. "verify-ca fails with an unknown CA, pass ?ca=/path/to/ca.pem in the URL"
      )
    end
  else
    local msg = type(store) == "table" and store.message or tostring(store)
    vim.health.warn(msg, {
      "Only needed for tls=verify-ca / verify-full; pass ?ca=/path/to/ca.pem in the URL",
      "or install the CA certificates package of your system (e.g. ca-certificates)",
    })
  end
end

---Name servers, needed for mongodb+srv:// URLs.
function M.dns()
  vim.health.start("DNS (mongodb+srv://)")
  if jit.os == "Windows" then
    vim.health.ok("lookups use the Windows resolver (DnsQuery)")
    return
  end
  local servers = require("dbdash.net.dns").nameservers()
  if #servers > 0 then
    vim.health.ok(
      "name servers from /etc/resolv.conf: "
        .. table.concat(
          vim.tbl_map(function(s)
            return s.host
          end, servers),
          ", "
        )
    )
  else
    vim.health.warn("no name servers in /etc/resolv.conf", "Only needed for mongodb+srv://; add ?dns=host:port to the URL")
  end
end

---Health check for a network database: the driver loads, plus the CA store.
---@param name string
---@param extra fun()?
function M.network(name, extra)
  return function()
    vim.health.start("Driver")
    M.driver(name)
    M.ca_store()
    if extra then
      extra()
    end
  end
end

return M
