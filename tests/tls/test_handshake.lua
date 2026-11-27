-- TLS 1.3 against `openssl s_server -rev` (reverses each received line).
local socket = require("dbdash.net.socket")
local tls = require("dbdash.net.tls")
local async = require("dbdash.util.async")
local eq = MiniTest.expect.equality

local FIX = vim.fn.getcwd() .. "/tests/fixtures/"
local PKI = FIX .. "pki/"
local servers = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      if vim.fn.executable("openssl") == 0 then
        MiniTest.skip("openssl not installed")
      end
    end,
    post_case = function()
      for _, s in ipairs(servers) do
        pcall(s.kill, s, 9)
      end
      servers = {}
    end,
  },
})

local function run(fn)
  local res
  async.run(fn, function(err, ...)
    res = { err = err, ... }
  end)
  vim.wait(20000, function()
    return res ~= nil
  end, 5)
  assert(res, "task did not finish")
  return res
end

---Start s_server; returns its port once it accepts connections.
---Ports come from below the usual ephemeral range (32768+): a port there may be held by an
---outgoing connection, so s_server cannot bind it, and a probe connect to it can even
---succeed by connecting the socket to itself. If s_server exits anyway, try another port.
local function server(args)
  for _ = 1, 5 do
    local port = 20000 + (vim.uv.hrtime() + math.random(0, 9999)) % 12000
    local cmd = { "openssl", "s_server", "-accept", tostring(port), "-rev", "-quiet" }
    vim.list_extend(cmd, args)
    local exited = false
    local proc = vim.system(cmd, { text = true }, function()
      exited = true
    end)
    servers[#servers + 1] = proc
    local up = vim.wait(5000, function()
      if exited then
        return true
      end
      local r = run(function()
        local s = socket.connect("127.0.0.1", port, { connect_timeout = 200 })
        s:close()
      end)
      return r.err == nil
    end, 50)
    -- Give a failed bind a moment to show up as an exit before trusting the probe.
    vim.wait(30, function()
      return exited
    end, 5)
    if up and not exited then
      return port
    end
  end
  error("s_server did not start")
end

local function fingerprint(cert)
  local out = vim
    .system(
      { "openssl", "x509", "-in", FIX .. cert, "-noout", "-fingerprint", "-sha256" },
      { text = true }
    )
    :wait()
  return "sha256:" .. out.stdout:match("=(%S+)")
end

local function echo(port, opts, line, addr)
  return run(function()
    local s = socket.connect(addr or "127.0.0.1", port, { timeout = 5000 })
    local session = tls.starttls(s, vim.tbl_extend("force", { host = "localhost" }, opts))
    s:write(line .. "\n")
    local back = s:read_until("\n")
    s:close()
    return back, session.suite_name, session.cert and session.cert.subject
  end)
end

local EC = { "-cert", FIX .. "ec_cert.pem", "-key", FIX .. "ec.key", "-tls1_3" }
local RSA = { "-cert", FIX .. "rsa_cert.pem", "-key", FIX .. "rsa2048.pem", "-tls1_3" }

T["EC certificate, AES-128-GCM, require mode"] = function()
  local port =
    server(vim.list_extend({ "-ciphersuites", "TLS_AES_128_GCM_SHA256" }, vim.deepcopy(EC)))
  local r = echo(port, { mode = "require" }, "hello world")
  eq(r.err, nil)
  eq({ r[1], r[2], r[3] }, { "dlrow olleh\n", "TLS_AES_128_GCM_SHA256", "dbdash-test-ec" })
end

T["RSA certificate (PSS), ChaCha20-Poly1305, pin mode"] = function()
  local port =
    server(vim.list_extend({ "-ciphersuites", "TLS_CHACHA20_POLY1305_SHA256" }, vim.deepcopy(RSA)))
  local url = require("dbdash.db.url")
  local fp = url.parse_fingerprint(fingerprint("rsa_cert.pem"))
  local r = echo(port, { mode = "pin", fingerprint = fp }, "abc")
  eq(r.err, nil)
  eq({ r[1], r[2], r[3] }, { "cba\n", "TLS_CHACHA20_POLY1305_SHA256", "dbdash-test-rsa" })
end

T["pin mode rejects another certificate"] = function()
  local port = server(vim.deepcopy(EC))
  local url = require("dbdash.db.url")
  local r = echo(
    port,
    { mode = "pin", fingerprint = url.parse_fingerprint(fingerprint("rsa_cert.pem")) },
    "x"
  )
  eq(r.err.phase, "tls")
  eq(
    r.err.message:find(
      "certificate fingerprint mismatch: the server presented " .. fingerprint("ec_cert.pem"),
      1,
      true
    ) ~= nil,
    true
  )
end

-- TLS 1.2: every suite we offer, with encrypt-then-MAC and extended master secret on and off.
local TLS12 = {
  { "ECDHE-ECDSA-AES128-GCM-SHA256", "ec" },
  { "ECDHE-ECDSA-AES256-GCM-SHA384", "ec" },
  { "ECDHE-ECDSA-CHACHA20-POLY1305", "ec" },
  { "ECDHE-ECDSA-AES128-SHA256", "ec" },
  { "ECDHE-ECDSA-AES256-SHA384", "ec" },
  { "ECDHE-ECDSA-AES128-SHA", "ec" },
  { "ECDHE-ECDSA-AES256-SHA", "ec", "-no_etm" },
  { "ECDHE-RSA-AES128-GCM-SHA256", "rsa" },
  { "ECDHE-RSA-AES256-GCM-SHA384", "rsa" },
  { "ECDHE-RSA-CHACHA20-POLY1305", "rsa" },
  { "ECDHE-RSA-AES128-SHA256", "rsa", "-no_etm" },
  { "ECDHE-RSA-AES256-SHA384", "rsa" },
  { "ECDHE-RSA-AES128-SHA", "rsa" },
  { "ECDHE-RSA-AES256-SHA", "rsa", "-no_ems" },
  { "AES128-GCM-SHA256", "rsa" },
  { "AES256-GCM-SHA384", "rsa" },
  { "AES128-SHA256", "rsa" },
  { "AES128-SHA", "rsa", "-no_etm" },
  { "AES256-SHA", "rsa" },
}

for _, case in ipairs(TLS12) do
  T["TLS 1.2 " .. case[1] .. (case[3] and (" " .. case[3]) or "")] = function()
    local args = vim.deepcopy(case[2] == "ec" and EC or RSA)
    args[#args] = "-tls1_2"
    vim.list_extend(args, { "-cipher", case[1] .. ":@SECLEVEL=0" })
    if case[3] then
      args[#args + 1] = case[3]
    end
    local port = server(args)
    local line = string.rep("abcdefghij", 50)
    local r = echo(port, { mode = "require" }, line)
    eq(r.err, nil)
    eq(r[1], line:reverse() .. "\n")
    eq(r[2]:match("^TLS_") ~= nil, true)
  end
end

T["TLS 1.2 with pin and verify-full"] = function()
  local url = require("dbdash.db.url")
  local port = server({
    "-cert",
    FIX .. "rsa_cert.pem",
    "-key",
    FIX .. "rsa2048.pem",
    "-tls1_2",
    "-cipher",
    "ECDHE-RSA-AES128-GCM-SHA256",
  })
  local r = echo(
    port,
    { mode = "pin", fingerprint = url.parse_fingerprint(fingerprint("rsa_cert.pem")) },
    "pin"
  )
  eq({ r.err, r[1] }, { nil, "nip\n" })
  port = server({
    "-cert",
    PKI .. "leaf.pem",
    "-key",
    PKI .. "leaf.key",
    "-cert_chain",
    PKI .. "inter.pem",
    "-tls1_2",
  })
  r = echo(
    port,
    { mode = "verify-full", ca = PKI .. "root.pem", host = "localhost" },
    "full",
    "localhost"
  )
  eq({ r.err, r[1] }, { nil, "lluf\n" })
  port = server({
    "-cert",
    PKI .. "leaf_wronghost.pem",
    "-key",
    PKI .. "leaf.key",
    "-cert_chain",
    PKI .. "inter.pem",
    "-tls1_2",
  })
  r = echo(
    port,
    { mode = "verify-full", ca = PKI .. "root.pem", host = "localhost" },
    "x",
    "localhost"
  )
  eq(r.err.message:find("host name mismatch") ~= nil, true)
end

T["TLS 1.3 only when requested"] = function()
  local port = server({ "-cert", FIX .. "ec_cert.pem", "-key", FIX .. "ec.key", "-tls1_2" })
  local r = echo(port, { mode = "require", tls12 = false }, "x")
  eq(r.err.phase, "tls")
end

T["downgrade sentinel is rejected"] = function()
  local hs = require("dbdash.net.tls.handshake")
  local random = string.rep("\1", 24) .. "DOWNGRD\1"
  local body = "\3\3" .. random .. "\0" .. "\192\47" .. "\0"
  local ok, err = pcall(hs.parse_server_hello, body)
  eq({ ok, err.message:find("downgrade") ~= nil }, { false, true })
  local plain = "\3\3" .. string.rep("\1", 32) .. "\0" .. "\192\47" .. "\0"
  eq(hs.parse_server_hello(plain).version, 0x0303)
end

T["data larger than one record"] = function()
  -- s_server reverses each chunk it reads (adding a newline), so collect all chunks.
  local port = server(vim.deepcopy(EC))
  local line = string.rep("0123456789", 4000)
  local r = run(function()
    local s = socket.connect("127.0.0.1", port, { timeout = 5000 })
    tls.starttls(s, { host = "localhost", mode = "require" })
    s:write(line .. "\n")
    local got = ""
    while #got:gsub("\n", "") < #line do
      got = got .. s:read_until("\n")
    end
    s:close()
    return (got:gsub("\n", ""))
  end)
  eq(r.err, nil)
  eq(#r[1], #line)
  local _, nines = r[1]:gsub("9", "")
  eq(nines, 4000)
end

local function pki_server(leaf, key, chain)
  local args = { "-cert", PKI .. leaf, "-key", PKI .. key, "-tls1_3" }
  if chain then
    vim.list_extend(args, { "-cert_chain", PKI .. chain })
  end
  return server(args)
end
local function verify_opts(extra)
  return vim.tbl_extend("force", { mode = "verify-full", ca = PKI .. "root.pem" }, extra or {})
end

T["verify-full: valid chain by name and by IP"] = function()
  local port = pki_server("leaf.pem", "leaf.key", "inter.pem")
  local r = echo(port, verify_opts({ host = "localhost" }), "ok", "localhost")
  eq({ r.err, r[1] }, { nil, "ko\n" })
  r = echo(port, verify_opts({ host = "127.0.0.1" }), "ok")
  eq({ r.err, r[1] }, { nil, "ko\n" })
end

T["verify-full: RSA-PSS signed leaf with an RSA key"] = function()
  local port = pki_server("leaf_pss.pem", "leaf_pss.key")
  local r = echo(port, verify_opts({ host = "localhost" }), "x")
  eq(r.err, nil)
end

T["verify-full: failures"] = function()
  local function err_for(leaf, key, chain, o)
    local port = pki_server(leaf, key, chain)
    local r = echo(port, verify_opts(o or { host = "localhost" }), "x")
    eq(r.err ~= nil, true)
    eq(r.err.phase, "tls")
    return r.err.message
  end
  eq(
    err_for("leaf_wronghost.pem", "leaf.key", "inter.pem"):find(
      "host name mismatch: the certificate is for example.com, not localhost"
    ) ~= nil,
    true
  )
  eq(
    err_for(
      "leaf.pem",
      "leaf.key",
      "inter.pem",
      { host = "localhost", ca = PKI .. "other_root.pem" }
    ):find("unable to find a trusted issuer") ~= nil,
    true
  )
  eq(
    err_for("leaf.pem", "leaf.key", nil):find('unable to find a trusted issuer for "dbdash leaf"')
      ~= nil,
    true
  )
  eq(err_for("leaf_expired.pem", "leaf.key", "inter.pem"):find("has expired") ~= nil, true)
end

T["verify-ca ignores the host name"] = function()
  local port = pki_server("leaf_wronghost.pem", "leaf.key", "inter.pem")
  local r = echo(port, verify_opts({ mode = "verify-ca", host = "localhost" }), "x")
  eq(r.err, nil)
end

T["verify-full with the system trust store (DBDASH_NET=1)"] = function()
  if vim.env.DBDASH_NET ~= "1" then
    MiniTest.skip("needs internet access (DBDASH_NET=1)")
  end
  local r = run(function()
    local s = socket.connect("www.google.com", 443, { timeout = 10000 })
    local session = tls.starttls(s, { host = "www.google.com", mode = "verify-full" })
    s:close()
    return session.cert.subject
  end)
  eq(r.err, nil)
end

T["tampered CertificateVerify is rejected"] = function()
  local hs = require("dbdash.net.tls.handshake")
  local x509 = require("dbdash.net.tls.x509")
  local asn1 = require("dbdash.net.tls.asn1")
  local f = assert(io.open(FIX .. "ec_cert.pem", "rb"))
  local cert = x509.parse(asn1.pem(f:read("*a"), "CERTIFICATE"))
  f:close()
  -- Sign the CertificateVerify content with openssl, then verify against another transcript.
  local th = string.rep("\7", 32)
  local content_file = vim.fn.tempname()
  local cf = assert(io.open(content_file, "wb"))
  cf:write(hs.verify_content(th))
  cf:close()
  local sig = vim
    .system({ "openssl", "dgst", "-sha256", "-sign", FIX .. "ec.key", content_file })
    :wait().stdout
  eq(hs.check_signature(cert, 0x0403, sig, th), true)
  eq(hs.check_signature(cert, 0x0403, sig, string.rep("\8", 32)), false)
  eq(
    select(2, hs.check_signature(cert, 0x0804, sig, th)),
    "signature algorithm does not match the certificate key"
  )
end

return T
