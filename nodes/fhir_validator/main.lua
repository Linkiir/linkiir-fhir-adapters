-- ---------------------------------------------------------------------------
-- FHIR Validator - Transform Custom
--
-- Validates an inbound FHIR resource against a FHIR server's $validate
-- operation and forwards it unchanged only on a clean pass. Anything else - an
-- invalid resource, a timeout, an HTTP failure, a malformed response, or a
-- profile the server cannot resolve - stops the node with an error, so an
-- unvalidated resource never reaches the next node.
--
-- Receive JSON -> Validate -> Pass or Stop.
--
-- All the HTTP handling and OperationOutcome interpretation live in the
-- fhir_validate library. The node reads two settings and decides pass/stop.
-- ---------------------------------------------------------------------------
-- The runtime puts this node's directory on package.path, and the fhir_validate
-- library ships flat here, so it is required by name with no path setup.
local FhirValidate = require 'fhir_validate'

function main(Data)
   local Config = linkiir.config.node()

   -- The two node settings. The FHIR server URL is required; the profile is
   -- optional and only used when the server can resolve it.
   local FHIR_BASE_URL    = Config['FHIR Server URL']
   local PROFILE_CANONICAL = Config['FHIR Profile']

   if not FHIR_BASE_URL or FHIR_BASE_URL == '' then
      error('FHIR Validator: no FHIR Server URL is configured')
   end

   local Result = FhirValidate.validate{
      data    = Data,
      baseUrl = FHIR_BASE_URL,
      profile = PROFILE_CANONICAL,
   }

   if not Result.valid then
      -- Invalid or indeterminate: stop. The summary carries issue severity and
      -- codes only, never the submitted resource, so it is safe to surface.
      -- Raising an error hands the failure to Linkiir's own error handling and
      -- prevents the resource being forwarded downstream.
      error('FHIR validation failed (' .. Result.status .. '): ' .. Result.summary)
   end

   -- Valid (including valid-with-warnings): forward the ORIGINAL bytes,
   -- unchanged, to the next node.
   linkiir.flow.push{ data = Data }
   linkiir.log.info('FHIR Validator: valid, forwarded. ' .. Result.summary)
end
