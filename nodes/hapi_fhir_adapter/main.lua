-- ---------------------------------------------------------------------------
-- HAPI FHIR Adapter - Source Custom
--
-- Runs on the node's Interval. Each poll searches the configured FHIR server for
-- the configured resource type and pushes every match downstream as a JSON
-- document.
--
-- Works against both ends of the HAPI family: the open public test server at
-- hapi.fhir.org, and a Smile OmniVera deployment behind OAuth2. The difference
-- is the Authentication field, not the code.
--
-- What to change where:
--   Resource Type, Search Query, connection and auth  ->  node config
--   the shape of what gets pushed                     ->  this script
--   how the FHIR server is called                     ->  hapi_fhir library
-- ---------------------------------------------------------------------------
-- The library modules live in the hapi_fhir/ subfolder, so add it to the module
-- search path before requiring them.
package.path = linkiir.sys.nodeDir() .. '/hapi_fhir/?.lua;' .. package.path

local HapiFhir = require 'hapi_fhir'

local DEFAULT_RESOURCE = 'Patient'

-- Turn "family=Smith&_count=20" into { family = 'Smith', _count = '20' }.
--
-- Values are kept verbatim; linkiir.link.web percent-encodes them when it builds
-- the query string.
local function parseSearchQuery(Query)
   local Params = {}
   for Pair in tostring(Query or ''):gmatch('[^&]+') do
      local Key, Value = Pair:match('^%s*([^=]+)=(.*)$')
      if Key then
         Params[Key:gsub('%s+$', '')] = Value
      end
   end
   return Params
end

-- Checked once per script VM rather than every poll: the CapabilityStatement is
-- the authority on what release a server speaks, and the Accept header's
-- fhirVersion parameter only asks. A base URL pointing at the wrong release is
-- the mistake this catches, and it would otherwise surface much later as
-- puzzling validation errors on individual resources.
local VersionChecked = false

local function checkServerVersion(Fhir, Configured)
   if VersionChecked then return end
   VersionChecked = true

   local Info, Err = Fhir:serverVersion()
   if not Info then
      linkiir.log.warn(string.format(
         'HAPI FHIR Adapter: could not read the server CapabilityStatement [%s] %s. '
         .. 'Continuing anyway - the searches below will report their own errors.',
         tostring(Err.code), tostring(Err.message)))
      return
   end
   if Info.simulated then return end

   if Info.release and Info.release ~= Configured then
      linkiir.log.warn(string.format(
         'HAPI FHIR Adapter: FHIR Version is set to %s but %s reports %s (%s). '
         .. 'Check the FHIR Base URL points at the intended release.',
         Configured, 'the server', Info.release, Info.fhirVersion))
   else
      linkiir.log.info(string.format('HAPI FHIR Adapter: connected to %s (FHIR %s)',
         Info.software or 'the FHIR server', Info.fhirVersion))
   end
end

function main()
   local Fhir, Config = HapiFhir.fromNodeConfig()

   local Resource = Config['Resource Type']
   if Resource == nil or Resource == '' then Resource = DEFAULT_RESOURCE end

   checkServerVersion(Fhir, Fhir.version)

   -- Max Pages 0 means "no limit". A large number stands in for infinity, which
   -- keeps the loop bounded even against a server that pages endlessly.
   local MaxPages = tonumber(Config['Max Pages']) or 1
   if MaxPages <= 0 then MaxPages = 10000 end

   local Result, Err = Fhir:searchAll{
      resource   = Resource,
      parameters = parseSearchQuery(Config['Search Query']),
      max_pages  = MaxPages,
   }
   if not Result then
      -- Logged rather than raised, so a transient outage does not stop the node
      -- and the next interval simply retries. Raise here instead if a failed poll
      -- should halt the workflow.
      linkiir.log.error(string.format('HAPI FHIR Adapter: %s search failed [%s] %s',
         Resource, tostring(Err.code), tostring(Err.message)))
      return
   end

   if Result.simulated then
      linkiir.log.info('HAPI FHIR Adapter: Live Mode is off, no request was sent.')
      return
   end

   -- A page failed partway through a multi-page walk. Whatever arrived before it
   -- is still good and gets pushed; the failure is reported so the gap is not
   -- silent.
   if Result.incomplete then
      linkiir.log.warn(string.format(
         'HAPI FHIR Adapter: paging stopped after %d page(s) [%s] %s. '
         .. 'Pushing the %d resource(s) collected so far.',
         Result.pages, tostring(Result.error and Result.error.code),
         tostring(Result.error and Result.error.message), #Result.resources))
   end

   if #Result.resources == 0 then
      linkiir.log.info('HAPI FHIR Adapter: no ' .. Resource
         .. ' resources matched the search.')
      return
   end

   for _, FhirResource in ipairs(Result.resources) do
      linkiir.flow.push{
         data = linkiir.json.serialize(FhirResource),
         metadata = {
            fhir_resource_type = FhirResource.resourceType or Resource,
            fhir_id            = FhirResource.id,
            fhir_version       = Fhir.version,
         },
      }
   end

   linkiir.log.info(string.format(
      'HAPI FHIR Adapter: pushed %d %s resource(s) from %d page(s).',
      #Result.resources, Resource, Result.pages))
end

-- ---------------------------------------------------------------------------
-- Other things this node can do
--
-- Read one resource by id:
--    local Patient, Err = Fhir:read{ resource = 'Patient', id = '596027' }
--
-- Create a resource. HAPI returns the stored resource, so Result.id is the new
-- server-assigned id:
--    local Created, Err = Fhir:create{
--       resource   = 'Patient',
--       parameters = {
--          resourceType = 'Patient',
--          name      = {{ use = 'official', family = 'Smith', given = {'James'} }},
--          gender    = 'male',
--          birthDate = '1980-01-15',
--       },
--    }
--
-- Upsert at a known id:
--    local Updated, Err = Fhir:update{
--       resource = 'Patient', id = 'mrn-100001',
--       parameters = { resourceType = 'Patient', id = 'mrn-100001', gender = 'male' },
--    }
--
-- HL7 v2 to FHIR: one inbound message usually becomes several resources. Post
-- them as one transaction so a half-mapped patient never lands:
--    local Bundle = HapiFhir.transactionBundle({ PatientResource, EncounterResource,
--                                                ObservationResource }, 'POST')
--    local Result, Err = Fhir:transaction{ bundle = Bundle }
--
-- Invoke an operation:
--    local Everything = Fhir:operation{
--       api            = 'Patient/596027/$everything',
--       get_parameters = { _count = '50' },
--    }
--
-- Prove the endpoint and release before relying on them:
--    local Info = Fhir:serverVersion()   -- { release = 'R4', fhirVersion = '4.0.1' }
--
-- Validate credentials without making a FHIR call:
--    local Ok, Err = Fhir:authenticate()
-- ---------------------------------------------------------------------------
