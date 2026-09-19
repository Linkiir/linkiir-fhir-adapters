-- FHIR Profiling Tools
-- Source HTTP node serving a browser UI for FHIR resource template generation
-- and profile authoring, across the FHIR versions the node ships.

-- The runtime puts this node's directory on package.path, and the fhir_profiling
-- library (all its modules) ships flat here, so it is required by name with no
-- path setup.
local FhirProfiling = require 'fhir_profiling'

-- A multi-version portal: the served UI can switch FHIR version at request
-- time, and each version's profiles/database load on first use.
local Portal = FhirProfiling.portalFromNodeConfig()
if not Portal then
   linkiir.log.error('Failed to initialise FHIR profiling portal; check Specifications Path')
end

function main(Data)
   linkiir.log.debug(Data)

   if not Portal then
      linkiir.link.web.respond{
         body        = '{"error":"FHIR profiling client not initialised"}',
         contentType = 'application/json',
         code        = 500,
      }
      return
   end

   Portal:handleRequest(Data)
end
