-- ---------------------------------------------------------------------------
-- Athena Adapter - Source Custom
--
-- Runs on the node's Interval. Each poll searches Athena for patients using
-- the proprietary REST API and pushes each match downstream as a JSON document.
--
-- What to change where:
--   Search Query and the connection fields  ->  node config
--   the shape of what gets pushed           ->  this script
--   how Athena is called                    ->  athena_health library
-- ---------------------------------------------------------------------------

-- The library modules live in the athena_health/ subfolder, so add it to the
-- module search path before requiring them.
package.path = linkiir.sys.nodeDir() .. '/athena_health/?.lua;' .. package.path

local AthenaHealth = require 'athena_health'

-- Turn "firstname=John&lastname=Smith" into { firstname = 'John', ... }.
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
   local Athena, Config = AthenaHealth.fromNodeConfig()

   local SearchParams = parseSearchQuery(Config['Search Query'])

   -- Search using the proprietary REST API
   local Results, Err = Athena:searchPatients{
      parameters = SearchParams,
   }

   if not Results then
      linkiir.log.error(string.format('Athena Adapter: patient search failed [%s] %s',
         tostring(Err.code), tostring(Err.message)))
      return
   end

   if Results.simulated then
      linkiir.log.info('Athena Adapter: Live Mode is off, no request was sent.')
      return
   end

   -- The proprietary API returns patients in a "patients" array
   local Patients = Results.patients or Results
   if type(Patients) ~= 'table' then
      linkiir.log.info('Athena Adapter: no patients matched the search.')
      return
   end

   -- Handle both array-style and object-style responses
   if #Patients == 0 and not Patients[1] then
      linkiir.log.info('Athena Adapter: no patients matched the search.')
      return
   end

   local Count = 0
   for _, Patient in ipairs(Patients) do
      linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
      Count = Count + 1
   end

   linkiir.log.info(string.format('Athena Adapter: pushed %d patient(s).', Count))
end

-- ---------------------------------------------------------------------------
-- Other things this node can do
--
-- Search using the FHIR R4 API instead:
--    local Bundle, Err = Athena:searchPatientsFhir{
--       parameters = {
--          ['ah-practice'] = 'Organization/a-1.Practice-1128700',
--          name = 'John',
--       },
--    }
--    if Bundle then
--       for _, Patient in ipairs(AthenaHealth.resources(Bundle)) do
--          linkiir.flow.push{ data = linkiir.json.serialize(Patient) }
--       end
--    end
--
-- Create a patient:
--    local Result, Err = Athena:createPatient{
--       parameters = {
--          dob = '03/21/2024',
--          departmentid = '1',
--          firstname = 'John',
--          lastname = 'Smith',
--       },
--    }
--    if Result then
--       linkiir.log.info('Created patient: ' .. linkiir.json.serialize(Result))
--    end
--
-- Generic request (any proprietary REST endpoint):
--    local Result, Err = Athena:request{
--       api = 'v1/1128700/departments',
--       parameters = { limit = '10' },
--    }
-- ---------------------------------------------------------------------------
