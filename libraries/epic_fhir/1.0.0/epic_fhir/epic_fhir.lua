-- ---------------------------------------------------------------------------
-- epic_fhir - Epic FHIR client
--
-- Require this module. The others (auth, http, jwt, token) are internals.
--
--    local EpicFhir = require 'epic_fhir'
--
--    function main()
--       local Epic = EpicFhir.fromNodeConfig()
--
--       local Bundle, Err = Epic:search{
--          resource   = 'Patient',
--          parameters = { family = 'Smith', birthdate = '1970-01-01' },
--       }
--       if not Bundle then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Patient in ipairs(EpicFhir.resources(Bundle)) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = Epic:read{ resource = 'Patient', id = 'eXYZ123' }
--    if not Result then
--       -- Err.code and Err.message are always set. Depending on the failure,
--       -- Err may also carry http_code, outcome or body.
--    end
--
-- Authentication is automatic: the first call that needs a token fetches one
-- and later calls reuse it until it nears expiry.
-- ---------------------------------------------------------------------------

local Http = require 'epic_fhir_http'
local Auth = require 'epic_fhir_auth'

local DEFAULT_BASE_URL = 'https://fhir.epic.com/interconnect-fhir-oauth/'
local DEFAULT_VERSION  = 'R4'
local DEFAULT_TIMEOUT  = 30

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
-- Epic answers with 201 and no body, so the result is
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

-- Invoke a FHIR operation, e.g. api = 'Patient/eXYZ123/$everything'.
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
--   BaseUrl    - root of the Epic endpoint; a trailing slash is added if absent
--   ClientId   - client id from the Epic app registration
--   PrivateKey - path to the PEM private key used to sign the JWT
--   Version    - FHIR release, defaults to R4
--   Timeout    - request timeout in seconds, defaults to 30
--   VerifyTls  - verify the server certificate, defaults to true
--   Live       - perform real FHIR requests, defaults to true
function M.new(T)
   T = T or {}

   local BaseUrl = T.BaseUrl
   if BaseUrl == nil or BaseUrl == '' then BaseUrl = DEFAULT_BASE_URL end
   if BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local Version = T.Version
   if Version == nil or Version == '' then Version = DEFAULT_VERSION end

   local Instance = setmetatable({}, Client)
   Instance.base_url    = BaseUrl
   Instance.client_id   = T.ClientId or ''
   Instance.private_key = T.PrivateKey or ''
   Instance.version     = Version
   Instance.timeout     = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls  = T.VerifyTls ~= false
   Instance.live        = T.Live ~= false

   -- Scoping the cached token by credential and environment stops a node that
   -- talks to two Epic instances from reusing the wrong one.
   Instance.cache_key   = Instance.client_id .. '@' .. Instance.base_url

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, so a script can read its own
-- additional fields without a second linkiir.config.node() call:
--
--    local Epic, Config = EpicFhir.fromNodeConfig()
--    local Resource = Config['Resource Type']
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance = M.new{
      BaseUrl    = Config['Base URL'],
      ClientId   = Config['Client ID'],
      PrivateKey = Config['Private Key Path'],
      Version    = Config['FHIR Version'],
      VerifyTls  = Config['Verify TLS'],
      Live       = Config['Live Mode'],
   }

   return Instance, Config
end

return M
