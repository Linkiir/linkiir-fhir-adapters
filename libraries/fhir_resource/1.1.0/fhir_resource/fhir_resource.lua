-- ---------------------------------------------------------------------------
-- fhir_resource - FHIR R4 resource builder (Patient and Observation)
--
-- Require this module. The clean helper is an internal.
--
--    local FhirResource = require 'fhir_resource'
--
--    function main(Data)
--       local Resource, Err = FhirResource.fromData(Data, linkiir.config.node())
--       if not Resource then
--          linkiir.log.error(Err.message)
--          return
--       end
--       linkiir.flow.push{ data = Resource }
--    end
--
-- fromData() parses the inbound JSON, maps its fields onto a FHIR R4 template
-- for the configured resource type, strips leftover nulls, and returns the
-- serialised result. With no config it builds a Patient, exactly as 1.0.0 did.
--
-- Shape safety
-- ------------
-- The template is filled with linkiir.json.null and cleaned afterwards. The
-- serializer treats an untagged empty table as a JSON array, so an object that
-- the clean pass empties would wrongly become []. Every array and object this
-- module builds is therefore tagged explicitly with linkiir.json.array /
-- linkiir.json.object, so the shape never depends on how many fields a sparse
-- input happened to populate.
-- ---------------------------------------------------------------------------

local Clean = require 'fhir_resource_clean'

local Array  = linkiir.json.array
local Object = linkiir.json.object
local Null   = linkiir.json.null

-- ---------------------------------------------------------------------------
-- Templates, built as tagged tables rather than parsed from a JSON string, so
-- the array-vs-object shape is fixed regardless of which fields survive the
-- clean pass. Unpopulated leaves are Null and removed by removeNulls.
-- ---------------------------------------------------------------------------

local function patientTemplate()
   return Object{
      resourceType = 'Patient',
      active       = Null,
      identifier   = Array{ Object{ system = Null, value = Null, use = Null } },
      name         = Array{ Object{ use = Null, family = Null, given = Array{ Null } } },
      telecom      = Array{ Object{ system = Null, value = Null, use = Null } },
      gender       = Null,
      birthDate    = Null,
      address      = Array{ Object{
         use = Null, line = Array{ Null },
         city = Null, state = Null, postalCode = Null, country = Null,
      } },
      managingOrganization = Object{ reference = Null, display = Null },
   }
end

local function observationTemplate()
   return Object{
      resourceType = 'Observation',
      status       = Null,
      code         = Object{
         coding = Array{ Object{ system = Null, code = Null, display = Null } },
         text   = Null,
      },
      subject          = Object{ reference = Null, display = Null },
      effectiveDateTime = Null,
      valueQuantity    = Object{
         value = Null, unit = Null, system = Null, code = Null,
      },
      valueString = Null,
   }
end

-- ---------------------------------------------------------------------------
-- Mappers. Each takes the fresh template and the parsed input, and returns the
-- populated template. Fields absent from the input are left Null and removed.
-- ---------------------------------------------------------------------------

-- Patient. Behaviour is intentionally identical to 1.0.0 for the same input,
-- so a node updating from 1.0.0 to 1.1.0 produces the same Patient - the only
-- change is that empty sub-objects can no longer serialise as [].
local function mapPatient(Template, Input, Config)
   local IdentifierSystem = Input.identifier_system
      or (Config and Config['Identifier System'])
      or nil

   if Input.family or Input.given then
      Template.name[1].use = 'official'
      Template.name[1].family = Input.family
      Template.name[1].given[1] = Input.given
   end
   if Input.gender then Template.gender = Input.gender end
   if Input.birthDate then Template.birthDate = Input.birthDate end
   if Input.active ~= nil then Template.active = Input.active end

   local TelecomIdx = 0
   if Input.phone then
      TelecomIdx = TelecomIdx + 1
      Template.telecom[TelecomIdx] = Object{ system = 'phone', value = Input.phone, use = 'home' }
   end
   if Input.email then
      TelecomIdx = TelecomIdx + 1
      Template.telecom[TelecomIdx] = Object{ system = 'email', value = Input.email, use = 'home' }
   end
   -- A tagged empty array serialises as [] but is then removed by the clean
   -- pass as an empty table, so an absent telecom disappears entirely rather
   -- than shipping an empty array. Leaving the template's placeholder Null in
   -- place achieves the same removal.
   if TelecomIdx == 0 then Template.telecom = Null end

   if Input.city or Input.state or Input.postalCode or Input.addressLine or Input.country then
      Template.address[1].use = 'home'
      Template.address[1].city = Input.city
      Template.address[1].state = Input.state
      Template.address[1].postalCode = Input.postalCode
      Template.address[1].country = Input.country
      if Input.addressLine then Template.address[1].line[1] = Input.addressLine end
   end

   if IdentifierSystem or Input.identifier_value then
      Template.identifier[1].system = IdentifierSystem
      Template.identifier[1].value = Input.identifier_value
      Template.identifier[1].use = 'usual'
   end

   return Template
end

-- Observation. A minimal vital-signs / lab-result shape: a code, a subject
-- reference, an effective time, and a value that is either a quantity or a
-- string. Enough to demonstrate a second resource type without pretending to
-- cover the whole Observation surface.
local function mapObservation(Template, Input, Config)
   Template.status = Input.status or 'final'

   if Input.code or Input.codeSystem or Input.codeDisplay then
      Template.code.coding[1].system = Input.codeSystem or 'http://loinc.org'
      Template.code.coding[1].code = Input.code
      Template.code.coding[1].display = Input.codeDisplay
   end
   if Input.codeText then Template.code.text = Input.codeText end

   if Input.subjectReference then
      Template.subject.reference = Input.subjectReference
   elseif Input.subjectDisplay then
      Template.subject.display = Input.subjectDisplay
   end

   if Input.effectiveDateTime then Template.effectiveDateTime = Input.effectiveDateTime end

   if Input.value ~= nil and tonumber(Input.value) ~= nil then
      Template.valueQuantity.value = tonumber(Input.value)
      Template.valueQuantity.unit = Input.unit
      Template.valueQuantity.system = Input.unitSystem or 'http://unitsofmeasure.org'
      Template.valueQuantity.code = Input.unitCode or Input.unit
      Template.valueString = Null   -- only one value[x] may be present
   elseif Input.valueString then
      Template.valueString = Input.valueString
      Template.valueQuantity = Null
   else
      Template.valueQuantity = Null
      Template.valueString = Null
   end

   return Template
end

local RESOURCES = {
   Patient     = { template = patientTemplate,     map = mapPatient },
   Observation = { template = observationTemplate, map = mapObservation },
}

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------
local M = {}

-- A fresh Patient template, for callers that want to map by hand. Kept for
-- compatibility with 1.0.0, which exposed M.template().
function M.template()
   return patientTemplate()
end

-- Build a FHIR resource from an inbound JSON message.
--
--   Data   - the inbound message, a JSON object as a string
--   Config - optional node config table (linkiir.config.node()); the
--            'Resource Type' and 'Identifier System' labels are read from it
--
-- Returns the serialised JSON string, or nil plus an error table
-- { code=, message= }.
function M.fromData(Data, Config)
   if Data == nil or Data == '' then
      return nil, { code = 'INPUT_ERROR', message = 'no input data received' }
   end

   local Ok, Input = pcall(linkiir.json.parse, Data)
   if not Ok then
      return nil, { code = 'PARSE_ERROR',
                    message = 'input is not valid JSON: ' .. tostring(Input) }
   end
   if type(Input) ~= 'table' then
      return nil, { code = 'INPUT_ERROR', message = 'input must be a JSON object' }
   end
   -- A JSON array parses to a table too, but it is not a patient record. A
   -- table with a [1] element is a sequence, not the field map this expects.
   if Input[1] ~= nil then
      return nil, { code = 'INPUT_ERROR',
                    message = 'input must be a JSON object, not an array' }
   end

   local ResourceType = (Config and Config['Resource Type']) or 'Patient'
   local Spec = RESOURCES[ResourceType]
   if not Spec then
      return nil, { code = 'CONFIG_ERROR',
                    message = 'unsupported Resource Type: ' .. tostring(ResourceType)
                       .. ' (supported: Patient, Observation)' }
   end

   local Resource = Spec.map(Spec.template(), Input, Config)
   Clean.removeNulls(Resource)

   -- A resource stripped to just its type is almost certainly a mapping miss,
   -- not a resource anyone wants to send onward. Report it rather than emit an
   -- all-but-empty resource.
   local Populated = false
   for Key in pairs(Resource) do
      if Key ~= 'resourceType' then Populated = true; break end
   end
   if not Populated then
      return nil, { code = 'MAPPING_ERROR',
                    message = 'no fields mapped onto the ' .. ResourceType
                       .. ' - check the input matches the expected field names' }
   end

   return linkiir.json.serialize(Resource)
end

return M
