-- ---------------------------------------------------------------------------
-- hapi_fhir - HAPI FHIR / Smile OmniVera client
--
-- Require this module. The others (auth, http, token) are internals.
--
--    local HapiFhir = require 'hapi_fhir'
--
--    function main()
--       local Fhir = HapiFhir.fromNodeConfig()
--
--       local Bundle, Err = Fhir:search{
--          resource   = 'Patient',
--          parameters = { family = 'Smith', _count = '20' },
--       }
--       if not Bundle then
--          linkiir.log.error(Err.message)
--          return
--       end
--
--       for _, Patient in ipairs(HapiFhir.resources(Bundle)) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Every method returns a result, or nil plus an error table:
--
--    local Result, Err = Fhir:read{ resource = 'Patient', id = '123' }
--    if not Result then
--       -- Err.code and Err.message are always set. Depending on the failure,
--       -- Err may also carry http_code, outcome or body.
--    end
--
-- One client, two very different servers
-- --------------------------------------
-- Smile OmniVera is built on HAPI FHIR, so both speak the same FHIR REST API and
-- one library reaches both. What differs is the edge:
--
--   public HAPI sandbox    hapi.fhir.org/baseR4 and /baseR5. Open - no
--                          Authorization header, no token endpoint, no SMART
--                          discovery document. Data is purged and reloaded, so
--                          ids are not stable.
--   Smile OmniVera         the base URL is issued per deployment and per tenant.
--                          Normally OAuth2 client_credentials, sometimes behind
--                          a gateway that issues its own bearer tokens.
--
-- So the auth mode is configuration rather than something this library assumes,
-- and the FHIR base URL is taken whole instead of being assembled from parts.
--
-- Writing as well as reading
-- --------------------------
-- create, update, delete and transaction are here because the intended use is
-- both directions: HL7 v2 in and FHIR out, and FHIR in and HL7 v2 out. For an
-- HL7 v2 message that maps to several resources at once, transaction() posts
-- them as a single atomic Bundle rather than as a sequence of calls that can
-- half-fail.
-- ---------------------------------------------------------------------------

local Http = require 'hapi_fhir_http'
local Auth = require 'hapi_fhir_auth'

local DEFAULT_BASE_URL = 'https://hapi.fhir.org/baseR4'
local DEFAULT_VERSION  = 'R4'
local DEFAULT_TIMEOUT  = 30
local DEFAULT_MAX_PAGES = 1

-- ---------------------------------------------------------------------------
-- Bundle helpers
--
-- Defined up here as locals because Client:searchAll below needs them, and
-- exported on the module at the bottom. Kept local rather than reached through
-- the module table so nothing leaks into the global namespace.
-- ---------------------------------------------------------------------------

-- Flatten a searchset Bundle into a plain list of resources.
--
-- Entries without a resource (such as search-mode outcomes) are skipped. Always
-- returns a table, so the result is safe to ipairs even for an empty or absent
-- Bundle.
local function bundleResources(Bundle)
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

-- The URL of a Bundle's `next` page, or nil when there is not one.
local function bundleNextLink(Bundle)
   if type(Bundle) ~= 'table' or type(Bundle.link) ~= 'table' then return nil end
   for _, Link in ipairs(Bundle.link) do
      if Link.relation == 'next' and type(Link.url) == 'string' and Link.url ~= '' then
         return Link.url
      end
   end
   return nil
end

-- Accepts what the node's FHIR Version dropdown offers, plus the bare codes, so
-- a script setting Version = 'R4' directly works too.
local VERSION_ALIASES = {
   ['R4']              = 'R4',
   ['R5']              = 'R5',
   ['FHIR R4 (4.0.1)'] = 'R4',
   ['FHIR R5 (5.0.0)'] = 'R5',
   ['4.0.1']           = 'R4',
   ['5.0.0']           = 'R5',
}

-- Maps the node's Authentication dropdown onto the modes hapi_fhir_auth knows.
local AUTH_ALIASES = {
   ['None (public test endpoint)'] = 'none',
   ['None']                        = 'none',
   ['none']                        = 'none',
   ['Bearer Token']                = 'bearer',
   ['bearer']                      = 'bearer',
   ['Basic']                       = 'basic',
   ['basic']                       = 'basic',
   ['OAuth2 Backend Services']     = 'oauth2',
   ['oauth2']                      = 'oauth2',
}

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
-- HAPI returns the stored resource in the body; a deployment configured to
-- return nothing yields { created = true, code = 201, location = <url> }.
function Client:create(T)
   return Http.request(self, {
      method     = 'post',
      api        = T.resource,
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- PUT /<resource>/<id> - creates or replaces the resource at that id.
function Client:update(T)
   return Http.request(self, {
      method     = 'put',
      api        = T.resource .. '/' .. tostring(T.id),
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   })
end

-- DELETE /<resource>/<id>.
function Client:delete(T)
   return Http.request(self, {
      method  = 'delete',
      api     = T.resource .. '/' .. tostring(T.id),
      headers = T.headers,
      live    = T.live,
   })
end

-- POST / with a transaction or batch Bundle.
--
-- The one call to reach for when an inbound HL7 v2 message becomes several
-- resources: a transaction Bundle either lands completely or not at all, so a
-- half-mapped patient never reaches the repository.
function Client:transaction(T)
   local Bundle = T.bundle or T.parameters
   return Http.request(self, {
      method     = 'post',
      api        = '',
      parameters = Bundle,
      headers    = T.headers,
      live       = T.live,
   })
end

-- Invoke a FHIR operation, e.g. api = 'Patient/123/$everything'.
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

-- GET /metadata - the server's CapabilityStatement.
--
-- The authority on what a server actually speaks. Worth calling once at startup:
-- it proves the base URL is a FHIR endpoint and reports the release, which the
-- Accept media type only requests.
function Client:capabilities(T)
   T = T or {}
   return Http.request(self, {
      method  = 'get',
      api     = 'metadata',
      headers = T.headers,
      live    = T.live,
   })
end

-- The FHIR release the server reports, as 'R4'/'R5', plus the raw version
-- string. Returns nil plus an error when /metadata cannot be read.
function Client:serverVersion(T)
   local Statement, Err = self:capabilities(T)
   if not Statement then return nil, Err end
   if Statement.simulated then return { simulated = true } end
   local Raw = tostring(Statement.fhirVersion or '')
   local Release = Raw:match('^4%.') and 'R4'
      or Raw:match('^5%.') and 'R5'
      or Raw:match('^3%.') and 'DSTU3'
      or nil
   return { release = Release, fhirVersion = Raw,
            software = type(Statement.software) == 'table' and Statement.software.name or nil }
end

-- Follow a searchset Bundle's `next` links and return every resource across the
-- pages, up to MaxPages requests in total (the first search counts as one).
--
-- Paging matters on these servers: HAPI answers a search with a page and a next
-- link rather than the whole result set, so a caller that reads only the first
-- Bundle silently sees a fraction of the matches.
--
-- The next link is followed verbatim. It is an absolute URL, and on HAPI it
-- points at a different path from the search that produced it
-- (`<base>?_getpages=<uuid>&_getpagesoffset=...`), so rebuilding it from parts
-- does not work.
function Client:searchAll(T)
   local MaxPages = tonumber(T.max_pages) or self.max_pages or DEFAULT_MAX_PAGES
   if MaxPages < 1 then MaxPages = 1 end

   local Bundle, Err = self:search{
      resource   = T.resource,
      parameters = T.parameters,
      headers    = T.headers,
      live       = T.live,
   }
   if not Bundle then return nil, Err end
   if Bundle.simulated then return { simulated = true, resources = {}, pages = 0 } end

   local Out = {}
   local Pages = 0
   while Bundle do
      Pages = Pages + 1
      for _, Resource in ipairs(bundleResources(Bundle)) do
         Out[#Out + 1] = Resource
      end
      if Pages >= MaxPages then break end
      local Next = bundleNextLink(Bundle)
      if not Next then break end
      local Following, NextErr = Http.request(self, {
         method  = 'get',
         url     = Next,
         headers = T.headers,
         live    = T.live,
      })
      if not Following then
         -- Report what was collected rather than discarding it: a page that
         -- fails halfway through a long walk should not lose the earlier pages.
         return { resources = Out, pages = Pages, incomplete = true, error = NextErr }
      end
      Bundle = Following
   end

   return { resources = Out, pages = Pages }
end

-- Force a token exchange, for validating credentials at startup. A no-op for
-- auth modes that carry no token.
function Client:authenticate()
   return Auth.authenticate(self)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------
local M = {}
M.Client = Client

-- Flatten a searchset Bundle into a plain list of resources. See bundleResources.
M.resources = bundleResources

-- The URL of a Bundle's `next` page, or nil when there is not one.
M.nextLink = bundleNextLink

-- Build a transaction Bundle from a list of resources, ready for
-- Client:transaction. The building block for an HL7 v2 to FHIR mapping, where
-- one message becomes a patient plus an encounter plus observations.
--
--   Resources - list of FHIR resource tables
--   Method    - 'POST' to create, or 'PUT' to upsert at each resource's own id
function M.transactionBundle(Resources, Method)
   Method = tostring(Method or 'POST'):upper()
   local Entries = {}
   for _, Resource in ipairs(Resources or {}) do
      local Request
      if Method == 'PUT' and Resource.id then
         Request = { method = 'PUT', url = Resource.resourceType .. '/' .. tostring(Resource.id) }
      else
         Request = { method = 'POST', url = Resource.resourceType }
      end
      Entries[#Entries + 1] = { resource = Resource, request = Request }
   end
   return { resourceType = 'Bundle', type = 'transaction', entry = Entries }
end

-- Build a client explicitly.
--
--   BaseUrl      - the FHIR base URL, e.g. https://hapi.fhir.org/baseR4
--   Version      - 'R4' or 'R5'; also accepts the dropdown's full labels
--   AuthMode     - 'none' | 'bearer' | 'basic' | 'oauth2', or a dropdown label
--   BearerToken  - static token, for AuthMode 'bearer'
--   Username     - for AuthMode 'basic'
--   Password     - for AuthMode 'basic'
--   TokenUrl     - OAuth2 token endpoint; empty tries SMART discovery
--   ClientId     - for AuthMode 'oauth2'
--   ClientSecret - for AuthMode 'oauth2'
--   Scope        - OAuth2 scope, e.g. 'system/*.read'
--   MaxPages     - default page limit for searchAll, defaults to 1
--   Timeout      - request timeout in seconds, defaults to 30
--   VerifyTls    - verify the server certificate, defaults to true
--   Live         - perform real requests, defaults to true
function M.new(T)
   T = T or {}

   local BaseUrl = T.BaseUrl
   if BaseUrl == nil or BaseUrl == '' then BaseUrl = DEFAULT_BASE_URL end
   -- A trailing slash is added because every path is appended directly. Without
   -- it, base 'https://host/baseR4' + 'Patient' becomes '.../baseR4Patient'.
   if BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local Version = VERSION_ALIASES[tostring(T.Version or '')] or DEFAULT_VERSION
   local AuthMode = AUTH_ALIASES[tostring(T.AuthMode or '')] or 'none'

   local Instance = setmetatable({}, Client)
   Instance.base_url      = BaseUrl
   Instance.version       = Version
   Instance.auth_mode     = AuthMode
   Instance.bearer_token  = T.BearerToken or ''
   Instance.username      = T.Username or ''
   Instance.password      = T.Password or ''
   Instance.token_url     = T.TokenUrl or ''
   Instance.client_id     = T.ClientId or ''
   Instance.client_secret = T.ClientSecret or ''
   Instance.scope         = T.Scope or ''
   Instance.max_pages     = tonumber(T.MaxPages) or DEFAULT_MAX_PAGES
   Instance.timeout       = tonumber(T.Timeout) or DEFAULT_TIMEOUT
   Instance.verify_tls    = T.VerifyTls ~= false
   Instance.live          = T.Live ~= false

   -- Scoping the cached token by credential and endpoint stops a node that talks
   -- to two environments from reusing the wrong one.
   Instance.cache_key = Instance.client_id .. '@'
      .. (Instance.token_url ~= '' and Instance.token_url or Instance.base_url)

   return Instance
end

-- Build a client from the current node's own configuration fields.
--
-- Returns the client and the raw config table, so a script can read its own
-- additional fields without a second linkiir.config.node() call:
--
--    local Fhir, Config = HapiFhir.fromNodeConfig()
--    local Resource = Config['Resource Type']
function M.fromNodeConfig()
   local Config = linkiir.config.node()
   local Instance = M.new{
      BaseUrl      = Config['FHIR Base URL'],
      Version      = Config['FHIR Version'],
      AuthMode     = Config['Authentication'],
      BearerToken  = Config['Bearer Token'],
      Username     = Config['Username'],
      Password     = Config['Password'],
      TokenUrl     = Config['Token URL'],
      ClientId     = Config['Client ID'],
      ClientSecret = Config['Client Secret'],
      Scope        = Config['Scope'],
      MaxPages     = Config['Max Pages'],
      VerifyTls    = Config['Verify TLS'],
      Live         = Config['Live Mode'],
   }
   return Instance, Config
end

return M
