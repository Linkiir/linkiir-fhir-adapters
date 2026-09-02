-- ---------------------------------------------------------------------------
-- FHIR Resource Creator - Transform Custom
--
-- Receives a JSON object with patient fields, maps them onto a FHIR R4 Patient
-- template, strips unused null-valued fields, and pushes the clean resource
-- downstream.
--
-- What to change where:
--   the field mapping and template shape  ->  fhir_resource library
--   what gets pushed downstream           ->  this script
-- ---------------------------------------------------------------------------

-- The library modules live in the fhir_resource/ subfolder.
package.path = linkiir.sys.nodeDir() .. '/fhir_resource/?.lua;' .. package.path

local FhirResource = require 'fhir_resource'

function main(Data)
   local Patient, Err = FhirResource.fromData(Data)

   if not Patient then
      linkiir.log.error(string.format(
         'FHIR Resource Creator: [%s] %s', Err.code, Err.message))
      return
   end

   linkiir.flow.push{ data = Patient }
   linkiir.log.info('FHIR Resource Creator: pushed Patient resource.')
end
