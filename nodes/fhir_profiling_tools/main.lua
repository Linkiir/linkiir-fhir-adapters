-- FHIR Profiling Tools
-- Source HTTP node serving a browser UI for FHIR resource template generation.

package.path = linkiir.sys.nodeDir() .. '/fhir_profiling/?.lua;' .. package.path

local FhirProfiling = require 'fhir_profiling'

local Client = FhirProfiling.fromNodeConfig()
if not Client then
   linkiir.log.error('Failed to initialise FHIR profiling client; check Specifications Path')
end

function main(Data)
   linkiir.log.debug(Data)

   if not Client then
      linkiir.link.web.respond{
         body        = '{"error":"FHIR profiling client not initialised"}',
         contentType = 'application/json',
         code        = 500,
      }
      return
   end

   Client:handleRequest(Data)
end
