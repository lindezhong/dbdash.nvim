-- SCRAM client (RFC 5802 / RFC 7677), shared by PostgreSQL and MongoDB.
local hmac = require("dbdash.crypto.hmac")
local pbkdf2 = require("dbdash.crypto.pbkdf2")
local util = require("dbdash.crypto.util")
local dberr = require("dbdash.util.error")

local M = {}

---@class dbdash.scram.Client
local Client = {}
Client.__index = Client

local function saslname(s)
  return (s:gsub("=", "=3D"):gsub(",", "=2C"))
end

---@param o { hash: table, user: string?, password: string, nonce: string? }
function M.new(o)
  local nonce = o.nonce or vim.base64.encode(require("dbdash.crypto.random").bytes(18))
  return setmetatable({
    hash = o.hash,
    password = o.password,
    nonce = nonce,
    first_bare = "n=" .. saslname(o.user or "") .. ",r=" .. nonce,
  }, Client)
end

---client-first-message.
function Client:first()
  return "n,," .. self.first_bare
end

---client-final-message for the server-first-message.
function Client:final(server_first)
  local attrs = {}
  for k, v in server_first:gmatch("(%a)=([^,]*)") do
    attrs[k] = v
  end
  if attrs.e then
    dberr.raise("auth", "SCRAM error from server: " .. attrs.e)
  end
  if not attrs.r or attrs.r:sub(1, #self.nonce) ~= self.nonce then
    dberr.raise("auth", "SCRAM server nonce does not extend the client nonce")
  end
  local iterations = tonumber(attrs.i)
  if not attrs.s or not iterations or iterations < 1 then
    dberr.raise("auth", "invalid SCRAM server-first message")
  end
  local h = self.hash
  local salted = pbkdf2.derive(h, self.password, vim.base64.decode(attrs.s), iterations, h.size)
  local client_key = hmac.hmac(h, salted, "Client Key")
  local final_no_proof = "c=biws,r=" .. attrs.r
  self.auth_message = self.first_bare .. "," .. server_first .. "," .. final_no_proof
  local signature = hmac.hmac(h, h.digest(client_key), self.auth_message)
  self.server_key = hmac.hmac(h, salted, "Server Key")
  return final_no_proof .. ",p=" .. vim.base64.encode(util.xor(client_key, signature))
end

---Check the server-final-message (proves the server knows the password).
function Client:verify(server_final)
  local err = server_final:match("e=([^,]+)")
  if err then
    dberr.raise("auth", "SCRAM error from server: " .. err)
  end
  local expected = vim.base64.encode(hmac.hmac(self.hash, self.server_key, self.auth_message))
  local got = server_final:match("v=([^,]+)")
  if not got or not util.equal(got, expected) then
    dberr.raise("auth", "SCRAM server signature mismatch (possible impostor server)")
  end
end

return M
