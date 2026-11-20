local x = require("dbdash.crypto.x25519")
local u = require("dbdash.crypto.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["RFC 7748 5.2 vectors"] = function()
  eq(u.hex(x.scalarmult(
    u.unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
    u.unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
  )), "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
  eq(u.hex(x.scalarmult(
    u.unhex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
    u.unhex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493")
  )), "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957")
end

T["RFC 7748 6.1 Diffie-Hellman"] = function()
  local a = u.unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  local b = u.unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
  eq(u.hex(x.public(a)), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  eq(u.hex(x.public(b)), "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
  local k = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
  eq(u.hex(x.scalarmult(a, x.public(b))), k)
  eq(u.hex(x.scalarmult(b, x.public(a))), k)
end

T["iterated 1000 times (RFC 7748 5.2)"] = function()
  local k = "\9" .. string.rep("\0", 31)
  local uu = k
  local t0 = vim.uv.hrtime()
  for _ = 1, 1000 do
    k, uu = x.scalarmult(k, uu), k
  end
  MiniTest.add_note(("x25519: %.2f ms per scalar multiplication"):format((vim.uv.hrtime() - t0) / 1e6 / 1000))
  eq(u.hex(k), "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51")
end

return T
