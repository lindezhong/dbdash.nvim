-- Trusted root certificates for tls=verify-full: the system store, or a CA file given
-- with ?ca=. Bundles are parsed once and cached by path and modification time.
local asn1 = require("dbdash.crypto.asn1")
local x509 = require("dbdash.net.tls.x509")

local M = {}

M.SYSTEM_FILES = {
  "/etc/ssl/certs/ca-certificates.crt", -- Debian, Ubuntu, Arch, Alpine
  "/etc/pki/tls/certs/ca-bundle.crt", -- Fedora, RHEL
  "/etc/ssl/ca-bundle.pem", -- openSUSE
  "/etc/ssl/cert.pem", -- macOS, Alpine, BSDs
}

---@class dbdash.tls.TrustStore
---@field certs dbdash.x509.Cert[]
---@field by_subject table<string, dbdash.x509.Cert[]>
---@field by_der table<string, boolean>
---@field source string
---@field intermediates dbdash.x509.Cert[]? extra intermediate CAs that may complete a chain
---  (Windows "CA" store); never trust anchors

local cache = {}

local function fail(msg, ...)
  require("dbdash.util.error").raise("tls", msg:format(...))
end

---Build a store from DER certificates (unparseable ones are skipped).
function M.from_ders(ders, source)
  local store = { certs = {}, by_subject = {}, by_der = {}, source = source }
  for _, der in ipairs(ders) do
    local ok, cert = pcall(x509.parse, der)
    if ok then
      store.certs[#store.certs + 1] = cert
      store.by_subject[cert.subject_der] = store.by_subject[cert.subject_der] or {}
      table.insert(store.by_subject[cert.subject_der], cert)
      store.by_der[der] = true
    end
  end
  return store
end

---All PEM "CERTIFICATE" blocks of a text as DER strings.
function M.pem_certs(text)
  local out = {}
  for body in
    text:gmatch("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-(.-)%-%-%-%-%-END CERTIFICATE%-%-%-%-%-")
  do
    out[#out + 1] = vim.base64.decode((body:gsub("%s", "")))
  end
  return out
end

---Load a PEM bundle file (cached by mtime).
function M.from_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    fail("CA file not found: %s", path)
  end
  local mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec
  local c = cache[path]
  if c and c.mtime == mtime then
    return c.store
  end
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  local ders = M.pem_certs(text)
  if #ders == 0 then
    -- A single DER certificate is accepted too.
    local ok = pcall(asn1.parse, text)
    if ok then
      ders = { text }
    else
      fail("no certificates found in %s", path)
    end
  end
  local store = M.from_ders(ders, path)
  cache[path] = { mtime = mtime, store = store }
  return store
end

---Windows ROOT store through crypt32 (a system DLL).
local function windows_store()
  local ffi = require("ffi")
  pcall(
    ffi.cdef,
    [[
    typedef struct { unsigned long dwCertEncodingType; unsigned char *pbCertEncoded;
                     unsigned long cbCertEncoded; void *pCertInfo; void *hCertStore; } DBDASH_CERT_CONTEXT;
    void *CertOpenStore(const char *lpszStoreProvider, unsigned long dwEncodingType, void *hCryptProv,
                        unsigned long dwFlags, const void *pvPara);
    const DBDASH_CERT_CONTEXT *CertEnumCertificatesInStore(void *hCertStore, const DBDASH_CERT_CONTEXT *pPrev);
    int CertCloseStore(void *hCertStore, unsigned long dwFlags);
  ]]
  )
  local crypt32 = ffi.load("crypt32")
  local PROV_SYSTEM_A = ffi.cast("const char *", 9) -- CERT_STORE_PROV_SYSTEM_A
  local READONLY = 0x8000
  local CURRENT_USER, LOCAL_MACHINE = 0x10000, 0x20000
  local function enum(name, location, into, seen)
    local h = crypt32.CertOpenStore(PROV_SYSTEM_A, 0, nil, location + READONLY, name)
    if h == nil then
      return
    end
    local ctx = crypt32.CertEnumCertificatesInStore(h, nil)
    while ctx ~= nil do
      local der = ffi.string(ctx.pbCertEncoded, ctx.cbCertEncoded)
      if not seen[der] then
        seen[der] = true
        into[#into + 1] = der
      end
      ctx = crypt32.CertEnumCertificatesInStore(h, ctx)
    end
    crypt32.CertCloseStore(h, 0)
  end
  -- Trust anchors: trusted roots, and the third-party roots Windows keeps up to date
  -- (AuthRoot). Intermediate CAs ("CA") only complete chains; they are not anchors.
  local roots, inters, seen = {}, {}, {}
  enum("ROOT", CURRENT_USER, roots, seen)
  enum("ROOT", LOCAL_MACHINE, roots, seen)
  enum("AuthRoot", LOCAL_MACHINE, roots, seen)
  enum("CA", CURRENT_USER, inters, seen)
  enum("CA", LOCAL_MACHINE, inters, seen)
  local store = M.from_ders(roots, "Windows certificate store")
  store.intermediates = {}
  for _, der in ipairs(inters) do
    local ok, cert = pcall(x509.parse, der)
    if ok then
      store.intermediates[#store.intermediates + 1] = cert
    end
  end
  return store
end

local system_store

---The system trust store.
function M.system()
  if jit.os == "Windows" then
    system_store = system_store or windows_store()
    return system_store
  end
  for _, path in ipairs(M.SYSTEM_FILES) do
    if vim.uv.fs_stat(path) then
      return M.from_file(path)
    end
  end
  fail(
    "no system CA bundle found (looked in %s); pass ?ca=/path/to/ca.pem",
    table.concat(M.SYSTEM_FILES, ", ")
  )
end

---Store for a connection: the ?ca= file (relative to base_dir) or the system store.
function M.for_info(ca, base_dir)
  if ca and ca ~= "" then
    -- No vim.fn here: the handshake runs in a libuv callback (fast event context).
    local path = ca:gsub("^~", vim.uv.os_homedir() or "~")
    if not (path:sub(1, 1) == "/" or path:match("^%a:[/\\]")) and base_dir then
      path = vim.fs.joinpath(base_dir, path)
    end
    return M.from_file(path)
  end
  return M.system()
end

return M
