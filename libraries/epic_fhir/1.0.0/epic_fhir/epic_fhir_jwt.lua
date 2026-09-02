-- ---------------------------------------------------------------------------
-- epic_fhir_jwt - signs JSON Web Tokens
--
-- Epic authenticates backend services with a signed JWT rather than a shared
-- secret, so this module underpins the whole adapter. It is a general-purpose
-- signer: RS* algorithms sign with a PEM private key, HS* with a shared secret.
--
--    local Jwt = require 'epic_fhir_jwt'
--
--    local Token, Err = Jwt.sign{
--       algo    = 'RS384',
--       key     = PrivateKeyPem,
--       header  = { alg = 'RS384', typ = 'JWT' },
--       payload = { iss = 'client-id', exp = os.time() + 250 },
--    }
-- ---------------------------------------------------------------------------

local M = {}

-- Epic issues tokens only for RS384 assertions. The rest are here so this
-- module stays usable as a plain JWT signer elsewhere.
--
-- `kind` selects the primitive: 'sign' is asymmetric (RSA private key),
-- 'hmac' is symmetric (shared secret). `digest` is the hash both take.
local ALGORITHMS = {
   RS256 = { kind = 'sign', digest = 'sha256' },
   RS384 = { kind = 'sign', digest = 'sha384' },
   RS512 = { kind = 'sign', digest = 'sha512' },
   HS256 = { kind = 'hmac', digest = 'sha256' },
   HS384 = { kind = 'hmac', digest = 'sha384' },
   HS512 = { kind = 'hmac', digest = 'sha512' },
}

-- JWT uses base64url, which differs from base64 in three ways: '+' becomes
-- '-', '/' becomes '_', and the '=' padding is dropped. Standard base64
-- produces tokens that Epic rejects, so this transform is required, not
-- cosmetic.
local function base64url(Data)
   local Encoded = linkiir.codec.base64.encode(Data)
   Encoded = Encoded:gsub('%+', '-')
   Encoded = Encoded:gsub('/', '_')
   Encoded = Encoded:gsub('=', '')
   return Encoded
end

-- Exposed so callers can decode a token they built, mainly for diagnostics.
M.base64url = base64url

-- Compute the signature over "<header>.<payload>" using the chosen algorithm.
local function signPayload(Algorithm, SigningInput, Key)
   if Algorithm.kind == 'sign' then
      return linkiir.sec.key.sign{
         data      = SigningInput,
         key       = Key,
         algorithm = Algorithm.digest,
      }
   end

   -- hex defaults to true on linkiir.sec.hmac, but a JWT signature is the raw
   -- digest bytes, so it has to be switched off here.
   return linkiir.sec.hmac{
      data      = SigningInput,
      key       = Key,
      algorithm = Algorithm.digest,
      hex       = false,
   }
end

-- Sign a token.
--
--   T.algo    - algorithm name, e.g. 'RS384'
--   T.key     - PEM private key for RS*, shared secret for HS*
--   T.header  - JWT header table
--   T.payload - JWT claims table
--
-- Returns the compact token string, or nil plus { code=, message= }.
-- Raises only on programmer error: an unknown algorithm or a missing key.
function M.sign(T)
   local Algorithm = ALGORITHMS[T.algo]
   if not Algorithm then
      error("epic_fhir_jwt.sign: unsupported algorithm '" .. tostring(T.algo) .. "'")
   end
   if not T.key or T.key == '' then
      error('epic_fhir_jwt.sign: missing signing key')
   end

   local SigningInput = base64url(linkiir.json.serialize(T.header))
      .. '.' .. base64url(linkiir.json.serialize(T.payload))

   local Signature, Err = signPayload(Algorithm, SigningInput, T.key)
   if not Signature then
      return nil, Err or {
         code    = 'JWT_SIGN_FAILED',
         message = 'signing produced no signature for algorithm ' .. tostring(T.algo),
      }
   end

   return SigningInput .. '.' .. base64url(Signature)
end

return M
