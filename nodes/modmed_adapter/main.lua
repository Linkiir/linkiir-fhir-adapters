-- ---------------------------------------------------------------------------
-- ModMed Adapter - Source Custom
--
-- Runs on the node's Interval. Each poll searches ModMed for the configured
-- resource type and pushes every match downstream as a JSON document.
--
-- What to change where:
--   Resource Type, Search Query and the connection fields  ->  node config
--   the shape of what gets pushed                          ->  this script
--   how ModMed is called                                   ->  modmed_fhir library
-- ---------------------------------------------------------------------------

-- The library modules live in the modmed_fhir/ subfolder, so add it to the
-- module search path before requiring them.
package.path = linkiir.sys.nodeDir() .. '/modmed_fhir/?.lua;' .. package.path

local ModMedFhir = require 'modmed_fhir'

local DEFAULT_RESOURCE = 'Patient'

-- Turn "_count=20&family=Smith" into { _count = '20', family = 'Smith' }.
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
   local ModMed, Config = ModMedFhir.fromNodeConfig()

   local Resource = Config['Resource Type']
   if Resource == nil or Resource == '' then Resource = DEFAULT_RESOURCE end

   local Bundle, Err = ModMed:search{
      resource   = Resource,
      parameters = parseSearchQuery(Config['Search Query']),
   }

   if not Bundle then
      -- Logged rather than raised, so a transient outage does not stop the node
      -- and the next interval simply retries.
      linkiir.log.error(string.format('ModMed Adapter: %s search failed [%s] %s',
         Resource, tostring(Err.code), tostring(Err.message)))
      return
   end

   if Bundle.simulated then
      linkiir.log.info('ModMed Adapter: Live Mode is off, no request was sent.')
      return
   end

   local Resources = ModMedFhir.resources(Bundle)
   if #Resources == 0 then
      linkiir.log.info('ModMed Adapter: no ' .. Resource .. ' resources matched the search.')
      return
   end

   for _, FhirResource in ipairs(Resources) do
      linkiir.flow.push{ data = linkiir.json.serialize(FhirResource) }
   end

   linkiir.log.info(string.format('ModMed Adapter: pushed %d %s resource(s).',
      #Resources, Resource))
end

-- ---------------------------------------------------------------------------
-- Other things this node can do
--
-- Read one resource by id:
--    local Patient, Err = ModMed:read{ resource = 'Patient', id = '123' }
--
-- Create a resource:
--    local Result, Err = ModMed:create{
--       resource   = 'Patient',
--       parameters = {
--          resourceType = 'Patient',
--          name      = {{ use = 'official', family = 'Doe', given = {'John'} }},
--          gender    = 'male',
--          birthDate = '1985-03-15',
--       },
--    }
--    if Result then
--       linkiir.log.info('Created patient at ' .. tostring(Result.location))
--    end
-- ---------------------------------------------------------------------------
