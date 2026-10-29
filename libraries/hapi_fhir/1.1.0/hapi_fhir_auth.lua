-- ---------------------------------------------------------------------------
-- hapi_fhir_auth - authentication for a HAPI FHIR / Smile OmniVera endpoint
--
-- Internal module. Four modes, because one adapter has to reach both ends of
-- the same family: a wide-open public HAPI sandbox, and a hardened Smile
-- OmniVera deployment.
--
--   none     no Authorization header at all. The public HAPI test server
--            (hapi.fhir.org) is open, and a locally-run hapi-fhir-jpaserver
--            ships with no security by default.
--   bearer   a static token pasted in by the operator. Useful for a short-lived
--            token during development, or an environment that issues long-lived
--            service tokens.
--   basic    username and password. Common on a self-hosted HAPI put behind
--            basic auth.
--   oauth2   OAuth 2.0 client_credentials. This is the unattended
--            (SMART Backend Services shaped) flow a production Smile OmniVera
--            endpoint expects.
--
-- Token endpoint discovery
-- -----------------------
-- For oauth2 the operator may paste a Token URL, or leave it empty and let this
-- module discover one from the FHIR base via SMART discovery:
--
--    <base>/.well-known/smart-configuration   ->  token_endpoint
--
-- Discovery is attempted once per client and cached, because a server that does
-- not publish it answers 404 and there is no point asking again every poll. The
-- public HAPI sandbox is one such server - it is open, so it publishes nothing.
--
-- Deliberately *not* implemented: the asymmetric private_key_jwt variant of
-- SMART Backend Services. Symmetric client_credentials is what Smile deployments
-- are normally provisioned with, and a JWT assertion mode belongs with the key
-- handling the Epic and Cerner libraries already carry. Pasting a Token URL
-- covers a deployment whose auth server sits elsewhere.
-- ---------------------------------------------------------------------------

local Token = require 'hapi_fhir_token'

local M = {}

-- Remembers per-client whether discovery has run, so a server without a
-- .well-known document is asked once rather than on every poll.
local Discovered = {}

local function err(Code, Message, Extra)
   local E = { code = Code, message = Message }
   for K, V in pairs(Extra or {}) do E[K] = V end
   return E
end

-- Base64 for the basic-auth header, via the platform encoder.
local function base64(Data)
   return linkiir.codec.base64.encode(Data)
end

-- The token endpoint to use: whatever was configured, else whatever the server
-- publishes. Returns url, or nil plus an error.
local function tokenUrl(Client)
   if Client.token_url and Client.token_url ~= '' then
      return Client.token_url
   end

   local Key = Client.cache_key
   if Discovered[Key] ~= nil then
      if Discovered[Key] == false then
         return nil, err('NO_TOKEN_ENDPOINT',
            'No Token URL is configured and this server does not publish one at '
            .. Client.base_url .. '.well-known/smart-configuration. '
            .. 'Set Token URL to the OAuth2 token endpoint for this environment.')
      end
      return Discovered[Key]
   end

   local Url = Client.base_url .. '.well-known/smart-configuration'
   local Response = linkiir.link.web.get{
      url       = Url,
      headers   = { Accept = 'application/json' },
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
   }

   local Found
   if Response and Response.code == 200 and Response.body and Response.body ~= '' then
      local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
      if Ok and type(Parsed) == 'table' and type(Parsed.token_endpoint) == 'string'
         and Parsed.token_endpoint ~= '' then
         Found = Parsed.token_endpoint
      end
   end

   Discovered[Key] = Found or false
   if not Found then
      return nil, err('NO_TOKEN_ENDPOINT',
         'No Token URL is configured and SMART discovery at ' .. Url
         .. ' did not return a token_endpoint. Set Token URL to the OAuth2 '
         .. 'token endpoint for this environment.')
   end
   linkiir.log.info('hapi_fhir: discovered token endpoint ' .. Found)
   return Found
end

-- Exchange client credentials for an access token.
local function fetchToken(Client)
   if Client.client_id == '' or Client.client_secret == '' then
      return nil, err('MISSING_CREDENTIALS',
         'Authentication is set to OAuth2 Backend Services, so Client ID and '
         .. 'Client Secret are both required.')
   end

   local Url, UrlErr = tokenUrl(Client)
   if not Url then return nil, UrlErr end

   local Form = {
      grant_type    = 'client_credentials',
      client_id     = Client.client_id,
      client_secret = Client.client_secret,
   }
   if Client.scope and Client.scope ~= '' then Form.scope = Client.scope end

   local Response, WebErr = linkiir.link.web.post{
      url       = Url,
      params    = Form,
      headers   = {
         ['Content-Type'] = 'application/x-www-form-urlencoded',
         ['Accept']       = 'application/json',
      },
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
   }
   if not Response then
      return nil, err('TOKEN_REQUEST_FAILED',
         'Token request to ' .. Url .. ' failed: ' .. tostring(WebErr))
   end
   if Response.code < 200 or Response.code >= 300 then
      -- The body usually carries the OAuth2 error code, which is the useful
      -- half of a 400 (invalid_client, invalid_scope, unsupported_grant_type).
      return nil, err('TOKEN_HTTP_' .. tostring(Response.code),
         'Token endpoint returned HTTP ' .. tostring(Response.code)
         .. (Response.body and Response.body ~= ''
             and (': ' .. tostring(Response.body):sub(1, 300)) or ''),
         { http_code = Response.code })
   end

   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok or type(Parsed) ~= 'table' or type(Parsed.access_token) ~= 'string' then
      return nil, err('TOKEN_PARSE_ERROR',
         'Token endpoint response did not contain an access_token')
   end

   -- expires_in is seconds and is optional; default to a conservative 5 minutes
   -- rather than assume an hour, so a short-lived token is not cached past use.
   local Lifetime = tonumber(Parsed.expires_in) or 300
   return Token.put(Client.cache_key, Parsed.access_token, os.time() + Lifetime)
end

-- The Authorization header value for this client, or nil when the mode needs
-- none. Returns value, nil on success; nil, Err on failure; nil, nil for the
-- 'none' mode, which is a success with nothing to add.
function M.header(Client)
   local Mode = Client.auth_mode

   if Mode == 'none' then
      return nil, nil
   end

   if Mode == 'bearer' then
      if Client.bearer_token == '' then
         return nil, err('MISSING_CREDENTIALS',
            'Authentication is set to Bearer Token, so Bearer Token is required.')
      end
      return 'Bearer ' .. Client.bearer_token
   end

   if Mode == 'basic' then
      if Client.username == '' then
         return nil, err('MISSING_CREDENTIALS',
            'Authentication is set to Basic, so Username is required.')
      end
      return 'Basic ' .. base64(Client.username .. ':' .. Client.password)
   end

   if Mode == 'oauth2' then
      local Entry = Token.get(Client.cache_key)
      if not Entry then
         local Fetched, FetchErr = fetchToken(Client)
         if not Fetched then return nil, FetchErr end
         Entry = Fetched
      end
      return 'Bearer ' .. Entry.token
   end

   return nil, err('UNKNOWN_AUTH_MODE',
      "Unknown Authentication mode '" .. tostring(Mode) .. "'")
end

-- Force a token exchange, for validating credentials without making a FHIR
-- call. A no-op for the modes that carry no token.
function M.authenticate(Client)
   if Client.auth_mode ~= 'oauth2' then
      return { authenticated = true, mode = Client.auth_mode }
   end
   Token.clear(Client.cache_key)
   local Entry, FetchErr = fetchToken(Client)
   if not Entry then return nil, FetchErr end
   return { authenticated = true, mode = 'oauth2', expires_at = Entry.expires_at }
end

return M
