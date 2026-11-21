-- P-256 wrapper over dbdash.crypto.ecdsa (kept for existing callers).
local C = require("dbdash.crypto.ecdsa").curves.p256

return {
  public_key = function(point)
    return C:public_key(point)
  end,
  verify = function(key, digest, sig)
    return C:verify(key, digest, sig)
  end,
  ecdh_keypair = function()
    return C:ecdh_keypair()
  end,
  ecdh = function(priv, peer)
    return C:ecdh(priv, peer)
  end,
}
