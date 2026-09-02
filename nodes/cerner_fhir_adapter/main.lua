-- ---------------------------------------------------------------------------
-- Cerner FHIR Adapter - Source Custom
--
-- Runs on the node's Interval. Each poll searches Cerner for the configured
-- resource type and pushes every match downstream as a JSON document.
--
-- What to change where:
--   Resource Type, Search Query and the connection fields  ->  node config
--   the shape of what gets pushed                          ->  this script
--   how Cerner is called                                   ->  cerner_fhir library
-- ---------------------------------------------------------------------------

-- The library modules live in the cerner_fhir/ subfolder, so add it to the
-- module search path before requiring them.
package.path = linkiir.sys.nodeDir() .. '/cerner_fhir/?.lua;' .. package.path

local CernerFhir = require 'cerner_fhir'

local DEFAULT_RESOURCE = 'Patient'

-- Turn "family=Smith&birthdate=1970-01-01" into { family = 'Smith', ... }.
--
-- Values are kept verbatim; linkiir.link.web percent-encodes them when it
-- builds the query string.
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

function main()
   local Cerner, Config = CernerFhir.fromNodeConfig()

   local Resource = Config['Resource Type']
   if Resource == nil or Resource == '' then Resource = DEFAULT_RESOURCE end

   local Bundle, Err = Cerner:search{
      resource   = Resource,
      parameters = parseSearchQuery(Config['Search Query']),
   }

   if not Bundle then
      linkiir.log.error(string.format('Cerner FHIR Adapter: %s search failed [%s] %s',
         Resource, tostring(Err.code), tostring(Err.message)))
      return
   end

   if Bundle.simulated then
      linkiir.log.info('Cerner FHIR Adapter: Live Mode is off, no request was sent.')
      return
   end

   local Resources = CernerFhir.resources(Bundle)
   if #Resources == 0 then
      linkiir.log.info('Cerner FHIR Adapter: no ' .. Resource .. ' resources matched the search.')
      return
   end

   for _, FhirResource in ipairs(Resources) do
      linkiir.flow.push{ data = linkiir.json.serialize(FhirResource) }
   end

   linkiir.log.info(string.format('Cerner FHIR Adapter: pushed %d %s resource(s).',
      #Resources, Resource))
end

-- ---------------------------------------------------------------------------
-- Other things this node can do
--
-- Read one resource by id:
--    local Patient, Err = Cerner:read{ resource = 'Patient', id = '12345' }
--
-- Create a resource:
--    local Result, Err = Cerner:create{
--       resource   = 'Patient',
--       parameters = {
--          resourceType = 'Patient',
--          name      = {{ use = 'official', family = 'Smart', given = {'Joe'} }},
--          gender    = 'male',
--          birthDate = '1990-01-01',
--       },
--    }
--    if Result then
--       linkiir.log.info('Created ' .. tostring(Result.location))
--    end
--
-- Search with custom parameters:
--    local Bundle, Err = Cerner:search{
--       resource   = 'Observation',
--       parameters = { patient = '12345', category = 'vital-signs' },
--    }
-- ---------------------------------------------------------------------------
