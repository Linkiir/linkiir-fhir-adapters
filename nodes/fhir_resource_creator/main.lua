-- ---------------------------------------------------------------------------
-- FHIR Resource Creator - Transform Custom
--
-- Receives a JSON object with source fields, maps them onto a FHIR R4 Patient
-- or Observation, strips unused fields, and pushes the clean resource
-- downstream. The resource type, identifier system and error handling are node
-- configuration.
--
-- What to change where:
--   the resource type, identifier system, error routing  ->  node config
--   the field mapping and template shape                 ->  fhir_resource library
--   what gets pushed downstream                          ->  this script
-- ---------------------------------------------------------------------------
-- The library modules live in the fhir_resource/ subfolder.
package.path = linkiir.sys.nodeDir() .. '/fhir_resource/?.lua;' .. package.path
local FhirResource = require 'fhir_resource'

function main(Data)
   local Config = linkiir.config.node()

   local Resource, Err = FhirResource.fromData(Data, Config)
   if not Resource then
      linkiir.log.error(string.format(
         'FHIR Resource Creator: [%s] %s', Err.code, Err.message))
      -- Optionally hand the original input to an error route for inspection.
      -- A malformed resource is never forwarded downstream either way.
      if Config['On Error'] == 'Push to error route'
         and Config['Error Topic'] and Config['Error Topic'] ~= '' then
         linkiir.flow.push{ data = Data, topic = Config['Error Topic'],
                            metadata = { fhir_create_error = Err.code } }
      end
      return
   end

   local ResourceType = Config['Resource Type'] or 'Patient'
   linkiir.flow.push{
      data = Resource,
      metadata = { fhir_resource_type = ResourceType },
   }
   linkiir.log.info('FHIR Resource Creator: pushed ' .. ResourceType .. ' resource.')
end
