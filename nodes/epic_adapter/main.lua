-- ---------------------------------------------------------------------------
-- EPIC Adapter - Source Custom
--
-- Runs on the node's Interval. Each poll searches Epic for the configured
-- resource type and pushes every match downstream as a JSON document.
--
-- What to change where:
--   Resource Type, Search Query and the connection fields  ->  node config
--   the shape of what gets pushed                          ->  this script
--   how Epic is called                                     ->  epic_fhir library
-- ---------------------------------------------------------------------------

-- The library modules live in the epic_fhir/ subfolder, so add it to the
-- module search path before requiring them.
package.path = linkiir.sys.nodeDir() .. '/epic_fhir/?.lua;' .. package.path

local EpicFhir = require 'epic_fhir'

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
   local Epic, Config = EpicFhir.fromNodeConfig()

   local Resource = Config['Resource Type']
   if Resource == nil or Resource == '' then Resource = DEFAULT_RESOURCE end

   local Bundle, Err = Epic:search{
      resource   = Resource,
      parameters = parseSearchQuery(Config['Search Query']),
   }

   if not Bundle then
      -- Logged rather than raised, so a transient Epic outage does not stop the
      -- node and the next interval simply retries. Raise here instead if a
      -- failed poll should halt the workflow.
      linkiir.log.error(string.format('EPIC Adapter: %s search failed [%s] %s',
         Resource, tostring(Err.code), tostring(Err.message)))
      return
   end

   if Bundle.simulated then
      linkiir.log.info('EPIC Adapter: Live Mode is off, no request was sent.')
      return
   end

   local Resources = EpicFhir.resources(Bundle)
   if #Resources == 0 then
      linkiir.log.info('EPIC Adapter: no ' .. Resource .. ' resources matched the search.')
      return
   end

   for _, FhirResource in ipairs(Resources) do
      linkiir.flow.push{ data = linkiir.json.serialize(FhirResource) }
   end

   linkiir.log.info(string.format('EPIC Adapter: pushed %d %s resource(s).',
      #Resources, Resource))
end

-- ---------------------------------------------------------------------------
-- Other things this node can do
--
-- Read one resource by id:
--    local Patient, Err = Epic:read{ resource = 'Patient', id = 'eXYZ123' }
--
-- Create a resource. Epic answers 201 with no body, so the new resource id
-- arrives in Result.location rather than in a returned resource:
--    local Result, Err = Epic:create{
--       resource   = 'Patient',
--       parameters = {
--          resourceType = 'Patient',
--          name      = {{ use = 'official', family = 'Lufhir', given = {'Sakiko'} }},
--          gender    = 'female',
--          birthDate = '1994-07-22',
--       },
--    }
--    if Result then
--       linkiir.log.info('Created ' .. tostring(Result.location))
--    end
--
-- Invoke an operation:
--    local Everything = Epic:operation{
--       api            = 'Patient/eXYZ123/$everything',
--       get_parameters = { _count = '50' },
--    }
-- ---------------------------------------------------------------------------
