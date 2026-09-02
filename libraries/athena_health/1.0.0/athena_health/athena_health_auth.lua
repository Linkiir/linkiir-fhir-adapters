-- ---------------------------------------------------------------------------
-- athena_health_auth - obtains an Athena access token
--
-- Implements client_credentials with Basic authentication. The client sends
-- its credentials as a Base64-encoded Authorization header and receives a
-- bearer token in return.
--
--    1. Build a Basic auth header: base64(client_id:client_secret)
--    2. POST grant_type=client_credentials&scope=<scopes> to the token URL
--    3. Cache the returned token until it nears expiry
--
-- Callers use M.ensure, which authenticates only when there is no usable token
-- to hand. M.authenticate forces a fresh exchange.
-- ---------------------------------------------------------------------------

local TokenCache = require 'athena_health_token'

local M = {}

-- Used when a token response omits expires_in.
local DEFAULT_TOKEN_LIFETIME = 3600

-- Percent-encode a flat table as application/x-www-form-urlencoded.
--
-- The token endpoint expects its grant fields in the request *body*. Passing
-- them as `params` to linkiir.link.web.post would put them in the query
-- string, where Athena does not look for them, so the form is built by hand.
local function formEncode(Params)
   local Parts = {}
   for Key, Value in pairs(Params) do
      Parts[#Parts + 1] = linkiir.codec.uri.encode(tostring(Key))
         .. '=' .. linkiir.codec.uri.encode(tostring(Value))
   end
   return table.concat(Parts, '&')
end

-- Exchange client credentials for a bearer token, storing it on the client and
-- in the shared cache. Returns the token, or nil plus { code=, message= }.
--
-- This always performs a live request, even when the client is simulating API
-- calls. A simulated token would make every later call fail as though the
-- credentials were wrong.
function M.authenticate(Client)
   if not Client.client_id or Client.client_id == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Client ID is not configured on this node',
      }
   end

   if not Client.client_secret or Client.client_secret == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Client Secret is not configured on this node',
      }
   end

   local TokenUrl = Client.base_url .. 'oauth2/v1/token'

   local BasicAuth = linkiir.codec.base64.encode(
      Client.client_id .. ':' .. Client.client_secret
   )

   local Body = formEncode{
      grant_type = 'client_credentials',
      scope      = Client.scopes or '',
   }

   local Response, WebErr = linkiir.link.web.post{
      url = TokenUrl,
      headers = {
         ['Content-Type']  = 'application/x-www-form-urlencoded',
         ['Accept']        = 'application/json',
         ['Authorization'] = 'Basic ' .. BasicAuth,
      },
      body      = Body,
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
         message = 'Athena token endpoint returned HTTP ' .. tostring(Response.code),
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
-- back to a fresh exchange.
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
