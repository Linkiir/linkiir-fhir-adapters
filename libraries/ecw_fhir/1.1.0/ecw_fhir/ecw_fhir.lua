-- ---------------------------------------------------------------------------
-- ecw_fhir - eCW FHIR client
--
-- Require this module. The others (auth, http, jwt, token) are internals.
--
--    local EcwFhir = require 'ecw_fhir'
--
--    function main()
--       local Ecw = EcwFhir.fromNodeConfig()
--
--       local Bundle, Err = Ecw:search{
--          resource   = 'Patient',
--          parameters = { family = 'Smith', birthdate = '1970-01-01' },
--       }
--       if not Bundle then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Patient in ipairs(EcwFhir.resources(Bundle)) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = Ecw:read{ resource = 'Patient', id = 'abc123' }
--    if not Result then
--       -- Err.code and Err.message are always set.
--    end
--
-- Authentication is automatic: the first call that needs a token fetches one
-- and later calls reuse it until it nears expiry.
-- ---------------------------------------------------------------------------

local Http = require 'ecw_fhir_http'
local Auth = require 'ecw_fhir_auth'

local DEFAULT_BASE_URL = 'https://staging-fhir.ecwcloud.com/fhir/r4/FFBJCD/'
local DEFAULT_AUTH_URL = 'https://staging-oauthserver.ecwcloud.com/'
local DEFAULT_VERSION  = 'r4'
local DEFAULT_TIMEOUT  = 30

-- ---------------------------------------------------------------------------
-- CapabilityStatement cache (lazy, per base URL)
-- ---------------------------------------------------------------------------

-- Module-level cache so the capability fetch happens at most once per
-- base URL across all polling intervals.
local CapabilityCache = {}

-- Fetch and parse the CapabilityStatement from the server's metadata endpoint.
-- Returns the parsed capability map keyed by resource type, or nil plus error.
local function fetchCapabilities(Client)
   local CacheKey = Client.base_url
   if CapabilityCache[CacheKey] then
      return CapabilityCache[CacheKey]
   end

   local Response, WebErr = linkiir.link.web.get{
      url       = Client.base_url .. 'metadata?_format=json',
      headers   = { ['Accept'] = 'application/fhir+json' },
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
      live      = true,
   }

   if not Response then
      return nil, WebErr or {
         code    = 'REQUEST_FAILED',
         message = 'CapabilityStatement fetch failed for ' .. Client.base_url,
      }
   end

   if Response.simulated then
      return nil, {
         code    = 'SIMULATED',
         message = 'cannot fetch CapabilityStatement in simulated mode',
      }
   end

   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok or type(Parsed) ~= 'table' then
      return nil, {
         code    = 'PARSE_ERROR',
         message = 'CapabilityStatement response was not valid JSON',
         body    = Response.body,
      }
   end

   -- Build the map: { ResourceType = { interaction = "read,search,...", parameters = {...} } }
   local Map = {}
   local Rest = Parsed.rest
   if type(Rest) ~= 'table' or type(Rest[1]) ~= 'table'
      or type(Rest[1].resource) ~= 'table' then
      return nil, {
         code    = 'PARSE_ERROR',
         message = 'CapabilityStatement has no rest[1].resource array',
      }
   end

   for _, Res in ipairs(Rest[1].resource) do
      local Entry = {}
      Entry.name = Res['type']

      -- Build interaction list
      local Interactions = {}
      if type(Res.interaction) == 'table' then
         for _, Inter in ipairs(Res.interaction) do
            Interactions[#Interactions + 1] = Inter.code
         end
      end
      Entry.interaction = table.concat(Interactions, ',')

      -- Build search parameters
      if Entry.interaction:find('search') and type(Res.searchParam) == 'table' then
         local Params = {}
         for _, Param in ipairs(Res.searchParam) do
            Params[#Params + 1] = {
               name          = Param.name,
               type          = Param['type'],
               documentation = Param.documentation,
            }
         end
         Entry.parameters = Params
      end

      Map[Res['type']] = Entry
   end

   CapabilityCache[CacheKey] = Map
   return Map
end

-- ---------------------------------------------------------------------------
-- Client methods
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

-- GET /<resource>?<parameters> - returns a searchset Bundle.
--
-- Empty string values are stripped from the parameters, matching the legacy
-- behaviour where parameters() returns a template with empty strings that the
-- caller fills in selectively.
function Client:search(T)
   local Params = {}
   if T.parameters then
      for K, V in pairs(T.parameters) do
         if V ~= '' then Params[K] = V end
      end
   end

   return Http.request(self, {
      method     = 'get',
      api        = T.resource,
      parameters = Params,
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

-- Return the searchable parameters for a resource type as a template table
-- with empty string values.
--
-- The CapabilityStatement is fetched lazily on first call and cached for the
-- lifetime of the node process.
function Client:parameters(ResourceType)
   local Caps, Err = fetchCapabilities(self)
   if not Caps then return nil, Err end

   local Entry = Caps[ResourceType]
   if not Entry then
      return nil, {
         code    = 'NOT_FOUND',
         message = ResourceType .. ' is not in the CapabilityStatement',
      }
   end

   local Template = {}
   if Entry.parameters then
      for _, Param in ipairs(Entry.parameters) do
         Template[Param.name] = ''
      end
   end

   return Template
end

-- GET /Group/<group_id>/$export - initiates a bulk export.
--
-- Returns the job id and retry-after on success, or nil plus error.
function Client:getBulk(T)
   local Api = 'Group/' .. tostring(T.group_id) .. '/$export'
   local Params = {}
   if T.resources then Params._type = T.resources end
   if T.since    then Params._since = T.since end
   if T.format   then Params._outputFormat = T.format end

   local Result, Err = Http.request(self, {
      method     = 'get',
      api        = Api,
      parameters = Params,
      headers    = { Prefer = 'respond-async' },
      live       = T.live,
   })

   if not Result then return nil, Err end

   -- The job id comes from the content-location header on a 202 response.
   if type(Result) == 'table' and Result.created and Result.location then
      local Parts = {}
      for Part in tostring(Result.location):gmatch('[^=]+') do
         Parts[#Parts + 1] = Part
      end
      return Parts[2] or Result.location
   end

   return Result
end

-- GET /$export-poll-location?job_id=<id> - checks bulk export status.
--
-- Returns true and a table of URLs keyed by resource type when complete,
-- or false plus retry info when still processing.
function Client:checkBulk(T)
   local Result, Err = Http.request(self, {
      method     = 'get',
      api        = '$export-poll-location',
      parameters = { job_id = T.job_id },
      headers    = { Accept = '*/*' },
      live       = T.live,
   })

   if not Result then return false, Err end

   -- A completed export returns a table with an output array.
   if type(Result) == 'table' and type(Result.output) == 'table' then
      local Urls = {}
      for _, Entry in ipairs(Result.output) do
         Urls[Entry['type']] = Entry.url
      end
      return true, Urls
   end

   -- Still processing
   return false, Result
end

-- GET <url> - downloads a bulk export file.
--
-- Returns a list of lines (NDJSON records), or nil plus error.
function Client:downloadBulk(T)
   local Result, Err = Http.request(self, {
      method  = 'get',
      url     = T.url,
      headers = { Accept = '*/*' },
      timeout = T.timeout,
      live    = T.live,
   })

   if not Result then return nil, Err end

   -- The raw body is NDJSON; split into lines.
   if type(Result) == 'string' then
      local Lines = {}
      for Line in Result:gmatch('[^\n]+') do
         Lines[#Lines + 1] = Line
      end
      return Lines
   end

   return Result
end

-- Escape hatch for anything the methods above do not cover.
function Client:request(T)
   return Http.request(self, T)
end

-- Force a token exchange. Not normally needed.
function Client:authenticate()
   return Auth.authenticate(self)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

M.Client = Client

-- Flatten a searchset Bundle into a plain list of resources.
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
--   BaseUrl    - root of the eCW FHIR endpoint
--   AuthUrl    - root of the eCW OAuth server (separate from FHIR base)
--   ClientId   - client id from the eCW app registration
--   PrivateKey - path to the PEM private key
--   Kid        - key id placed in the JWT header
--   Version    - FHIR release, defaults to r4
--   Scopes     - OAuth scopes for the token request
--   Timeout    - request timeout in seconds, defaults to 30
--   VerifyTls  - verify the server certificate, defaults to true
--   Live       - perform real FHIR requests, defaults to true
function M.new(T)
   T = T or {}

   local BaseUrl = T.BaseUrl
   if BaseUrl == nil or BaseUrl == '' then BaseUrl = DEFAULT_BASE_URL end
   if BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local AuthUrl = T.AuthUrl
   if AuthUrl == nil or AuthUrl == '' then AuthUrl = DEFAULT_AUTH_URL end
   if AuthUrl:sub(-1) ~= '/' then AuthUrl = AuthUrl .. '/' end

   local Version = T.Version
   if Version == nil or Version == '' then Version = DEFAULT_VERSION end

   local Instance = setmetatable({}, Client)
   Instance.base_url    = BaseUrl
   Instance.auth_url    = AuthUrl
   Instance.client_id   = T.ClientId or ''
   Instance.private_key = T.PrivateKey or ''
   Instance.kid         = T.Kid or ''
   Instance.version     = Version:lower()
   Instance.timeout     = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls  = T.VerifyTls ~= false
   Instance.live        = T.Live ~= false

   -- Scopes for the token request. eCW requires these (unlike Epic).
   local Scopes = T.Scopes
   if Scopes and Scopes ~= '' then
      Instance.scopes = Scopes
   end

   -- Scoping the cached token by credential and auth environment.
   Instance.cache_key = Instance.client_id .. '@' .. Instance.auth_url

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, so a script can read its own
-- additional fields without a second linkiir.config.node() call:
--
--    local Ecw, Config = EcwFhir.fromNodeConfig()
--    local Resource = Config['Resource Type']
function M.fromNodeConfig()
   local Config = linkiir.config.node()

   local Instance = M.new{
      BaseUrl    = Config['Base URL'],
      AuthUrl    = Config['Auth URL'],
      ClientId   = Config['Client ID'],
      PrivateKey = Config['Private Key Path'],
      Kid        = Config['Key ID'],
      Version    = Config['FHIR Version'],
      Scopes     = Config['Scopes'],
      VerifyTls  = Config['Verify TLS'],
      Live       = Config['Live Mode'],
   }

   return Instance, Config
end

return M
