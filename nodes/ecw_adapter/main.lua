-- ---------------------------------------------------------------------------
-- eCW Adapter - Source Custom
--
-- Runs on the node's Interval. Each poll searches eCW for the configured
-- resource type and pushes every match downstream as a JSON document.
--
-- What to change where:
--   Resource Type, Search Query and the connection fields  ->  node config
--   the shape of what gets pushed                          ->  this script
--   how eCW is called                                      ->  ecw_fhir library
-- ---------------------------------------------------------------------------

-- The library modules live in the ecw_fhir/ subfolder, so add it to the
-- module search path before requiring them.
package.path = linkiir.sys.nodeDir() .. '/ecw_fhir/?.lua;' .. package.path

local EcwFhir = require 'ecw_fhir'

local DEFAULT_RESOURCE = 'Patient'

-- Turn "family=Smith&birthdate=1970-01-01" into { family = 'Smith', ... }.
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
   local Ecw, Config = EcwFhir.fromNodeConfig()

   local Resource = Config['Resource Type']
   if Resource == nil or Resource == '' then Resource = DEFAULT_RESOURCE end

   local Bundle, Err = Ecw:search{
      resource   = Resource,
      parameters = parseSearchQuery(Config['Search Query']),
   }

   if not Bundle then
      linkiir.log.error(string.format('eCW Adapter: %s search failed [%s] %s',
         Resource, tostring(Err.code), tostring(Err.message)))
      return
   end

   if Bundle.simulated then
      linkiir.log.info('eCW Adapter: Live Mode is off, no request was sent.')
      return
   end

   local Resources = EcwFhir.resources(Bundle)
   if #Resources == 0 then
      linkiir.log.info('eCW Adapter: no ' .. Resource .. ' resources matched the search.')
      return
   end

   for _, FhirResource in ipairs(Resources) do
      linkiir.flow.push{ data = linkiir.json.serialize(FhirResource) }
   end

   linkiir.log.info(string.format('eCW Adapter: pushed %d %s resource(s).',
      #Resources, Resource))
end
