-- ---------------------------------------------------------------------------
-- cerner_fhir - Cerner FHIR client
--
-- Require this module. The others (auth, http, jwt, token) are internals.
--
--    local CernerFhir = require 'cerner_fhir'
--
--    function main()
--       local Cerner = CernerFhir.fromNodeConfig()
--
--       local Bundle, Err = Cerner:search{
--          resource   = 'Patient',
--          parameters = { family = 'smart', given = 'joe' },
--       }
--       if not Bundle then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Patient in ipairs(CernerFhir.resources(Bundle)) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = Cerner:read{ resource = 'Patient', id = '12345' }
--    if not Result then
--       -- Err.code and Err.message are always set. Depending on the failure,
--       -- Err may also carry http_code, outcome or body.
--    end
--
-- Authentication is automatic: the first call that needs a token fetches one
-- and later calls reuse it until it nears expiry.
-- ---------------------------------------------------------------------------

local Http = require 'cerner_fhir_http'
local Auth = require 'cerner_fhir_auth'

local DEFAULT_TIMEOUT = 30

-- ---------------------------------------------------------------------------
-- Client methods
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

-- GET /<resource>?<parameters> - returns a searchset Bundle.
function Client:search(T)
   return Http.request(self, {
      method     = 'get',
      api        = T.resource,
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- GET /<resource>/<id> - returns the resource.
function Client:read(T)
   return Http.request(self, {
      method  = 'get',
      api     = T.resource .. '/' .. tostring(T.id),
      headers = T.headers,
      live    = T.live,
   })
end

-- POST /<resource> - creates the resource.
--
-- Cerner answers with 201 and no body, so the result is
-- { created = true, code = 201, location = '<new resource id>' }.
function Client:create(T)
   return Http.request(self, {
      method     = 'post',
      api        = T.resource,
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- PUT /<resource>/<id> - replaces the resource.
function Client:update(T)
   return Http.request(self, {
      method     = 'put',
      api        = T.resource .. '/' .. tostring(T.id),
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- Invoke a FHIR operation, e.g. api = 'Patient/12345/$everything'.
--
-- Pass get_parameters for a GET-style invocation, or parameters to POST a
-- Parameters resource.
function Client:operation(T)
   if T.get_parameters then
      return Http.request(self, {
         method     = 'get',
         api        = T.api,
         parameters = T.get_parameters,
         headers    = T.headers,
         live       = T.live,
      })
   end

   return Http.request(self, {
      method     = 'post',
      api        = T.api,
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- Escape hatch for anything the methods above do not cover. Takes the same
-- shape as they pass down: { method=, api=, parameters=, headers=, live= }.
function Client:request(T)
   return Http.request(self, T)
end

-- Force a token exchange. Not normally needed, since requests authenticate on
-- demand; useful to validate credentials at startup.
function Client:authenticate()
   return Auth.authenticate(self)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

M.Client = Client

-- Flatten a searchset Bundle into a plain list of resources.
--
-- Entries without a resource (such as search-mode outcomes) are skipped. Always
-- returns a table, so the result is safe to ipairs even for an empty or absent
-- Bundle.
function M.resources(Bundle)
   local Out = {}
   if type(Bundle) ~= 'table' or type(Bundle.entry) ~= 'table' then
      return Out
   end

   for _, Entry in ipairs(Bundle.entry) do
      if Entry.resource then
         Out[#Out + 1] = Entry.resource
      end
   end

   return Out
end

-- Build a client explicitly.
--
--   BaseUrl    - root of the Cerner FHIR endpoint; a trailing slash is added if absent
--   ClientId   - OAuth client identifier from the Cerner app registration
--   PrivateKey - path to the PEM private key used to sign the JWT
--   KeyId      - kid (Key ID) identifying the public key in your JWKS
--   Scopes     - SMART on FHIR scopes requested for the token
--   Timeout    - request timeout in seconds, defaults to 30
--   VerifyTls  - verify the server certificate, defaults to true
--   Live       - perform real FHIR requests, defaults to true
function M.new(T)
   T = T or {}

   local BaseUrl = T.BaseUrl
   if BaseUrl == nil or BaseUrl == '' then
      error('cerner_fhir.new: BaseUrl is required')
   end
   if BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local Instance = setmetatable({}, Client)
   Instance.base_url    = BaseUrl
   Instance.client_id   = T.ClientId or ''
   Instance.private_key = T.PrivateKey or ''
   Instance.key_id      = T.KeyId or ''
   Instance.scopes      = T.Scopes or ''
   Instance.timeout     = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls  = T.VerifyTls ~= false
   Instance.live        = T.Live ~= false

   -- Scoping the cached token by credential and environment stops a node that
   -- talks to two Cerner instances from reusing the wrong one.
   Instance.cache_key   = Instance.client_id .. '@' .. Instance.base_url

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, so a script can read its own
-- additional fields without a second linkiir.config.node() call:
--
--    local Cerner, Config = CernerFhir.fromNodeConfig()
--    local Resource = Config['Resource Type']
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance = M.new{
      BaseUrl    = Config['Base URL'],
      ClientId   = Config['Client ID'],
      PrivateKey = Config['Private Key Path'],
      KeyId      = Config['Key ID'],
      Scopes     = Config['Scopes'],
      VerifyTls  = Config['Verify TLS'],
      Live       = Config['Live Mode'],
   }

   return Instance, Config
end

return M
