-- ---------------------------------------------------------------------------
-- athena_health - Athena Health client
--
-- Require this module. The others (auth, http, token) are internals.
--
--    local AthenaHealth = require 'athena_health'
--
--    function main()
--       local Athena, Config = AthenaHealth.fromNodeConfig()
--
--       local Results, Err = Athena:searchPatients{
--          parameters = { firstname = 'John' },
--       }
--       if not Results then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Patient in ipairs(Results.patients or {}) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Athena exposes two distinct APIs:
--   * Proprietary REST: v1/<practice_id>/patients (searchPatients, createPatient)
--   * FHIR R4: /fhir/r4/Patient (searchPatientsFhir)
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = Athena:searchPatients{ parameters = { firstname = 'John' } }
--    if not Result then
--       -- Err.code and Err.message are always set
--    end
--
-- Authentication is automatic: the first call that needs a token fetches one
-- and later calls reuse it until it nears expiry.
-- ---------------------------------------------------------------------------

local Http = require 'athena_health_http'
local Auth = require 'athena_health_auth'

local DEFAULT_TIMEOUT = 30

-- ---------------------------------------------------------------------------
-- Client methods
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

-- Search patients using the proprietary REST API.
-- GET v1/<practice_id>/patients?<parameters>
function Client:searchPatients(T)
   return Http.request(self, {
      method     = 'get',
      api        = 'v1/' .. self.practice_id .. '/patients',
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- Search patients using the FHIR R4 API.
-- GET /fhir/r4/Patient?<parameters>
function Client:searchPatientsFhir(T)
   return Http.request(self, {
      method     = 'get',
      api        = 'fhir/r4/Patient',
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- Create a patient using the proprietary REST API.
-- POST v1/<practice_id>/patients with form-encoded body.
function Client:createPatient(T)
   return Http.request(self, {
      method     = 'post',
      api        = 'v1/' .. self.practice_id .. '/patients',
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- Generic request against the proprietary REST API.
-- Allows any path below the base URL.
--
--   T.api        - path below base URL, e.g. 'v1/1128700/patients'
--   T.method     - HTTP verb, defaults to 'get'
--   T.parameters - query params for GET, form-encoded body for POST
--   T.headers    - extra headers
--   T.live       - live flag override
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

-- Flatten a FHIR searchset Bundle into a plain list of resources.
--
-- Entries without a resource are skipped. Always returns a table.
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
--   BaseUrl      - root of the Athena API platform; trailing slash added if absent
--   ClientId     - OAuth client id
--   ClientSecret - OAuth client secret
--   Scopes       - space-separated scopes
--   PracticeId   - the practice id for proprietary REST API calls
--   Timeout      - request timeout in seconds, defaults to 30
--   VerifyTls    - verify the server certificate, defaults to true
--   Live         - perform real API requests, defaults to true
function M.new(T)
   T = T or {}

   local BaseUrl = T.BaseUrl
   if BaseUrl == nil or BaseUrl == '' then
      BaseUrl = 'https://api.platform.athenahealth.com/'
   end
   if BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local Instance = setmetatable({}, Client)
   Instance.base_url      = BaseUrl
   Instance.client_id     = T.ClientId or ''
   Instance.client_secret = T.ClientSecret or ''
   Instance.scopes        = T.Scopes or ''
   Instance.practice_id   = T.PracticeId or ''
   Instance.timeout       = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls    = T.VerifyTls ~= false
   Instance.live          = T.Live ~= false

   -- Scoping the cached token by credential and environment stops a node that
   -- talks to two Athena environments from reusing the wrong one.
   Instance.cache_key = Instance.client_id .. '@' .. Instance.base_url

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, so a script can read its own
-- additional fields without a second linkiir.config.node() call:
--
--    local Athena, Config = AthenaHealth.fromNodeConfig()
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance = M.new{
      BaseUrl      = Config['Base URL'],
      ClientId     = Config['Client ID'],
      ClientSecret = Config['Client Secret'],
      Scopes       = Config['Scopes'],
      PracticeId   = Config['Practice ID'],
      VerifyTls    = Config['Verify TLS'],
      Live         = Config['Live Mode'],
   }

   return Instance, Config
end

return M
