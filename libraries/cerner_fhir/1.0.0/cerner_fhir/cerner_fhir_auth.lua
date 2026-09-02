-- ---------------------------------------------------------------------------
-- cerner_fhir_auth - obtains a Cerner access token
--
-- Implements Cerner's SMART-on-FHIR backend services flow. Like Epic, the
-- client proves its identity by signing a short-lived JWT with a private key
-- whose public half is registered as a JWKS on the CernerCentral System Account.
--
-- Key differences from Epic:
--   - The JWT header includes a `kid` (Key ID) claim identifying which public
--     key in the JWKS Cerner should use for verification.
--   - The token request body includes a `scope` parameter.
--   - The token endpoint is discovered from the well-known configuration.
--
--    1. Discover the token URL from <base>/.well-known/smart-configuration
--    2. Build a JWT with kid in the header
--    3. Sign it with the RSA private key (RS384)
--    4. POST it to the token URL as a form-encoded body, including scope
--    5. Cache the returned token until it nears expiry
--
-- Callers use M.ensure, which authenticates only when there is no usable token
-- to hand. M.authenticate forces a fresh exchange.
-- ---------------------------------------------------------------------------

local Jwt        = require 'cerner_fhir_jwt'
local TokenCache = require 'cerner_fhir_token'

local M = {}

local CLIENT_ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'

-- Cerner rejects assertions that are valid for longer than five minutes.
local ASSERTION_LIFETIME = 250

-- The algorithm Cerner requires for backend service assertions.
local ASSERTION_ALGORITHM = 'RS384'

-- Used when a token response omits expires_in.
local DEFAULT_TOKEN_LIFETIME = 3600

-- Percent-encode a flat table as application/x-www-form-urlencoded.
--
-- The token endpoint expects its grant fields in the request *body*. Passing
-- them as `params` to linkiir.link.web.post would put them in the query
-- string, where Cerner does not look for them, so the form is built by hand
-- and passed as `body`.
local function formEncode(Params)
   local Parts = {}
   for Key, Value in pairs(Params) do
      Parts[#Parts + 1] = linkiir.codec.uri.encode(tostring(Key))
         .. '=' .. linkiir.codec.uri.encode(tostring(Value))
   end
   return table.concat(Parts, '&')
end

-- Read the PEM private key from disk.
--
-- The key is read per authentication rather than held in memory for the life
-- of the node, so rotating the file takes effect at the next token exchange.
local function readPrivateKey(Path)
   if not Path or Path == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Private Key Path is not configured on this node',
      }
   end

   local File, OpenErr = io.open(Path, 'rb')
   if not File then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'cannot open private key at ' .. Path .. ': ' .. tostring(OpenErr),
      }
   end

   local Pem = File:read('*a')
   File:close()

   if not Pem or Pem == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'private key file is empty: ' .. Path,
      }
   end

   return Pem
end

-- Discover the token endpoint from the SMART well-known configuration.
-- The result is cached on the client so subsequent calls do not repeat the
-- discovery request.
local function discoverTokenUrl(Client)
   if Client.token_url then return Client.token_url end

   local WellKnownUrl = Client.base_url .. '.well-known/smart-configuration'
   local Response, WebErr = linkiir.link.web.get{
      url       = WellKnownUrl,
      headers   = { ['Accept'] = 'application/fhir+json' },
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
      live      = true,
   }

   if not Response then
      return nil, WebErr or {
         code    = 'DISCOVERY_FAILED',
         message = 'well-known request to ' .. WellKnownUrl .. ' failed',
      }
   end

   if Response.code ~= 200 then
      return nil, {
         code    = 'DISCOVERY_FAILED',
         message = 'well-known endpoint returned HTTP ' .. tostring(Response.code),
         body    = Response.body,
      }
   end

   local Ok, WellKnown = pcall(linkiir.json.parse, Response.body)
   if not Ok or type(WellKnown) ~= 'table' or not WellKnown.token_endpoint then
      return nil, {
         code    = 'DISCOVERY_FAILED',
         message = 'well-known response did not contain a token_endpoint',
         body    = Response.body,
      }
   end

   Client.token_url = WellKnown.token_endpoint
   return Client.token_url
end

-- Build the signed client assertion.
--
-- `aud` must be the exact token URL the assertion is sent to, and `jti` must
-- be unique per request; Cerner rejects the assertion otherwise.
-- The `kid` in the header identifies which key from the JWKS to use for
-- verification - this is the main structural difference from Epic.
local function buildAssertion(Client, TokenUrl)
   if not Client.client_id or Client.client_id == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Client ID is not configured on this node',
      }
   end

   if not Client.key_id or Client.key_id == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Key ID is not configured on this node',
      }
   end

   local Pem, KeyErr = readPrivateKey(Client.private_key)
   if not Pem then return nil, KeyErr end

   return Jwt.sign{
      algo = ASSERTION_ALGORITHM,
      key  = Pem,
      header = {
         alg = ASSERTION_ALGORITHM,
         typ = 'JWT',
         kid = Client.key_id,
      },
      payload = {
         iss = Client.client_id,
         sub = Client.client_id,
         aud = TokenUrl,
         jti = linkiir.sys.guid(512),
         exp = os.time() + ASSERTION_LIFETIME,
      },
   }
end

-- Exchange a signed assertion for a bearer token, storing it on the client and
-- in the shared cache. Returns the token, or nil plus { code=, message= }.
--
-- This always performs a live request, even when the client is simulating FHIR
-- calls. A simulated token would make every later call fail as though the
-- credentials were wrong, which hides the real problem.
function M.authenticate(Client)
   local TokenUrl, DiscoverErr = discoverTokenUrl(Client)
   if not TokenUrl then return nil, DiscoverErr end

   local Assertion, AssertionErr = buildAssertion(Client, TokenUrl)
   if not Assertion then return nil, AssertionErr end

   local Response, WebErr = linkiir.link.web.post{
      url = TokenUrl,
      headers = {
         ['Content-Type'] = 'application/x-www-form-urlencoded',
         ['Accept']       = 'application/json',
      },
      body = formEncode{
         grant_type            = 'client_credentials',
         client_assertion_type = CLIENT_ASSERTION_TYPE,
         client_assertion      = Assertion,
         scope                 = Client.scopes,
      },
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
      live      = true,
   }

   if not Response then
      return nil, WebErr or {
         code    = 'AUTH_FAILED',
         message = 'token request to ' .. TokenUrl .. ' failed',
      }
   end

   if Response.code ~= 200 then
      return nil, {
         code    = 'AUTH_FAILED',
         message = 'Cerner token endpoint returned HTTP ' .. tostring(Response.code),
         body    = Response.body,
      }
   end

   local Ok, Auth = pcall(linkiir.json.parse, Response.body)
   if not Ok or type(Auth) ~= 'table' or not Auth.access_token then
      return nil, {
         code    = 'AUTH_FAILED',
         message = 'token response was not JSON containing an access_token',
         body    = Response.body,
      }
   end

   Client.key        = Auth.access_token
   Client.key_expiry = os.time() + (tonumber(Auth.expires_in) or DEFAULT_TOKEN_LIFETIME)
   TokenCache.put(Client.cache_key, Client.key, Client.key_expiry)

   return Client.key
end

-- Return a usable token, authenticating only if needed.
--
-- Checks the token already on the client, then the shared cache, then falls
-- back to a fresh exchange. Every request goes through here, so a token is
-- fetched once and reused until it nears expiry.
function M.ensure(Client)
   if Client.key and Client.key_expiry
      and Client.key_expiry - TokenCache.EXPIRY_SKEW > os.time() then
      return Client.key
   end

   local Cached = TokenCache.get(Client.cache_key)
   if Cached then
      Client.key        = Cached.token
      Client.key_expiry = Cached.expires_at
      return Client.key
   end

   return M.authenticate(Client)
end

return M
