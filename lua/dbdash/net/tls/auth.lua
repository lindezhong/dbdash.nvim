-- Authentication of the server's certificate (TLS 1.2 and 1.3 handshakes), by mode.
local record = require("dbdash.net.tls.record")
local sha256 = require("dbdash.crypto.sha256")
local util = require("dbdash.crypto.util")

local M = {}

local fail = record.fail

-- Modes that require the server to prove possession of its certificate key.
M.STRICT = { pin = true, ["verify-ca"] = true, ["verify-full"] = true }

---Authenticate the server's certificate list (DER strings, leaf first) for the mode:
---pin compares the leaf fingerprint; verify-ca / verify-full validate the chain against
---the trust store, and verify-full also the host name. Returns the parsed leaf.
---@param ders string[]
---@param opts { host: string, mode: string, fingerprint: string?, ca: string?, base_dir: string? }
---@return dbdash.x509.Cert
function M.authenticate(ders, opts)
  local x509 = require("dbdash.net.tls.x509")
  local der = ders[1]
  if not der then
    fail("the server sent no certificate")
  end
  local fp = x509.fingerprint(der)
  if opts.mode == "pin" and not util.equal(sha256.digest(der), opts.fingerprint) then
    fail("certificate fingerprint mismatch: the server presented %s", fp)
  end
  local ok, cert = pcall(x509.parse, der)
  if not ok then
    if M.STRICT[opts.mode] then
      error(cert, 0)
    end
    -- the certificate does not parse: only what pinning needs (require and pin modes)
    ---@diagnostic disable-next-line: missing-fields
    cert = { der = der } --[[@as dbdash.x509.Cert]]
  end
  cert.fingerprint = fp
  if opts.mode == "verify-ca" or opts.mode == "verify-full" then
    local verify = require("dbdash.net.tls.verify")
    local inters = {}
    for k = 2, #ders do
      local iok, ic = pcall(x509.parse, ders[k])
      if iok then
        inters[#inters + 1] = ic
      end
    end
    local store = require("dbdash.net.tls.truststore").for_info(opts.ca, opts.base_dir)
    local vok, why = verify.chain(cert, inters, store)
    if not vok then
      fail("certificate verification failed: %s (presented %s)", why, fp)
    end
    if opts.mode == "verify-full" then
      local hok, hwhy = verify.host(cert, opts.host)
      if not hok then
        fail("certificate verification failed: %s", hwhy)
      end
    end
  end
  return cert
end

return M
