-- ---------------------------------------------------------------------------
-- modmed_fhir - ModMed FHIR client
--
-- Require this module. The others (auth, http, token) are internals.
--
--    local ModMedFhir = require 'modmed_fhir'
--
--    function main()
--       local ModMed = ModMedFhir.fromNodeConfig()
--
--       local Bundle, Err = ModMed:search{
--          resource   = 'Patient',
--          parameters = { _count = '20' },
--       }
--       if not Bundle then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Patient in ipairs(ModMedFhir.resources(Bundle)) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = ModMed:read{ resource = 'Patient', id = '123' }
--    if not Result then
--       -- Err.code and Err.message are always set. Depending on the failure,
--       -- Err may also carry http_code, outcome or body.
--    end
--
-- Authentication is automatic: the first call that needs a token fetches one
-- via a password grant, and later calls reuse or refresh it.
-- ---------------------------------------------------------------------------

local Http = require 'modmed_fhir_http'
local Auth = require 'modmed_fhir_auth'

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
function Client:create(T)
   return Http.request(self, {
      method     = 'post',
      api        = T.resource,
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
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
-- returns a table, so the result is safe to ipairs even for an empty Bundle.
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
--   BaseUrl    - root of the ModMed endpoint; a trailing slash is added if absent
--   Username   - account username
--   Password   - account password
--   ApiKey     - x-api-key sent on every request
--   Timeout    - request timeout in seconds, defaults to 30
--   VerifyTls  - verify the server certificate, defaults to true
--   Live       - perform real FHIR requests, defaults to true
function M.new(T)
   T = T or {}

   local BaseUrl = T.BaseUrl
   if BaseUrl == nil or BaseUrl == '' then
      error('modmed_fhir.new: BaseUrl is required')
   end
   if BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local Instance = setmetatable({}, Client)
   Instance.base_url   = BaseUrl
   Instance.username   = T.Username or ''
   Instance.password   = T.Password or ''
   Instance.api_key    = T.ApiKey or ''
   Instance.timeout    = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls = T.VerifyTls ~= false
   Instance.live       = T.Live ~= false

   -- Scoping the cached token by credential and environment stops a node that
   -- talks to two ModMed instances from reusing the wrong one.
   Instance.cache_key  = Instance.username .. '@' .. Instance.base_url

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, so a script can read its own
-- additional fields without a second linkiir.config.node() call:
--
--    local ModMed, Config = ModMedFhir.fromNodeConfig()
--    local Resource = Config['Resource Type']
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance = M.new{
      BaseUrl   = Config['Base URL'],
      Username  = Config['Username'],
      Password  = Config['Password'],
      ApiKey    = Config['API Key'],
      VerifyTls = Config['Verify TLS'],
      Live      = Config['Live Mode'],
   }

   return Instance, Config
end

return M
