-- ---------------------------------------------------------------------------
-- modmed_fhir_auth - obtains a ModMed access token
--
-- ModMed uses a two-stage token flow:
--
--    1. Initial login: POST grant_type=password with username and password
--    2. Subsequent calls: POST grant_type=refresh_token with the stored
--       refresh token
--
-- The x-api-key header is required on the token request as well as on every
-- FHIR request. The token endpoint is at <base_url>ws/oauth2/grant.
--
-- Callers use M.ensure, which authenticates only when there is no usable token
-- cached. M.authenticate forces a fresh password grant.
-- ---------------------------------------------------------------------------

local TokenCache = require 'modmed_fhir_token'

local M = {}

-- Used when a token response omits expires_in.
local DEFAULT_TOKEN_LIFETIME = 3600

-- Percent-encode a flat table as application/x-www-form-urlencoded.
--
-- The token endpoint expects its grant fields in the request body. Passing them
-- as `params` to linkiir.link.web.post would put them in the query string,
-- where the endpoint does not look for them.
local function formEncode(Params)
   local Parts = {}
   for Key, Value in pairs(Params) do
      Parts[#Parts + 1] = linkiir.codec.uri.encode(tostring(Key))
         .. '=' .. linkiir.codec.uri.encode(tostring(Value))
   end
   return table.concat(Parts, '&')
end

-- Exchange credentials for a bearer token, storing it on the client and in the
-- shared cache. Returns the token, or nil plus { code=, message= }.
local function exchangeToken(Client, Body)
   local TokenUrl = Client.base_url .. 'ws/oauth2/grant'

   local Response, WebErr = linkiir.link.web.post{
      url = TokenUrl,
      headers = {
         ['Content-Type'] = 'application/x-www-form-urlencoded',
         ['Accept']       = 'application/json',
         ['x-api-key']    = Client.api_key,
      },
      body = formEncode(Body),
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
         message = 'ModMed token endpoint returned HTTP ' .. tostring(Response.code),
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

   Client.key           = Auth.access_token
   Client.refresh_token = Auth.refresh_token
   Client.key_expiry    = os.time() + (tonumber(Auth.expires_in) or DEFAULT_TOKEN_LIFETIME)
   TokenCache.put(Client.cache_key, Client.key, Client.refresh_token, Client.key_expiry)

   return Client.key
end

-- Authenticate with a password grant. This is the initial login path.
function M.authenticate(Client)
   if not Client.username or Client.username == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Username is not configured on this node',
      }
   end
   if not Client.password or Client.password == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'Password is not configured on this node',
      }
   end
   if not Client.api_key or Client.api_key == '' then
      return nil, {
         code    = 'CONFIG_ERROR',
         message = 'API Key is not configured on this node',
      }
   end

   return exchangeToken(Client, {
      grant_type = 'password',
      username   = Client.username,
      password   = Client.password,
   })
end

-- Refresh the token using the stored refresh token.
function M.refresh(Client)
   if not Client.refresh_token or Client.refresh_token == '' then
      -- No refresh token available, fall back to password grant.
      return M.authenticate(Client)
   end

   local Token, Err = exchangeToken(Client, {
      grant_type    = 'refresh_token',
      refresh_token = Client.refresh_token,
   })

   if not Token then
      -- Refresh failed; attempt a fresh password login.
      linkiir.log.info('modmed_fhir: refresh token expired, re-authenticating with password')
      return M.authenticate(Client)
   end

   return Token
end

-- Return a usable token, authenticating only if needed.
--
-- Checks the token already on the client, then the shared cache, then falls
-- back to a password grant.
function M.ensure(Client)
   if Client.key and Client.key_expiry
      and Client.key_expiry - TokenCache.EXPIRY_SKEW > os.time() then
      return Client.key
   end

   local Cached = TokenCache.get(Client.cache_key)
   if Cached then
      Client.key           = Cached.token
      Client.refresh_token = Cached.refresh_token
      Client.key_expiry    = Cached.expires_at
      return Client.key
   end

   return M.authenticate(Client)
end

return M
