-- ---------------------------------------------------------------------------
-- fhir_resource - FHIR Patient resource builder
--
-- Require this module. The clean helper is an internal.
--
--    local FhirResource = require 'fhir_resource'
--
--    function main(Data)
--       local Patient, Err = FhirResource.fromData(Data)
--       if not Patient then
--          linkiir.log.error(Err.message)
--          return
--       end
--       linkiir.flow.push{ data = Patient }
--    end
--
-- fromData() parses the inbound JSON, maps fields onto a FHIR R4 Patient
-- template, strips leftover nulls, and returns the serialised result.
-- ---------------------------------------------------------------------------

local Clean = require 'fhir_resource_clean'

-- ---------------------------------------------------------------------------
-- FHIR R4 Patient template
--
-- Every possible field is present as null. After mapping, the clean pass
-- removes anything that was never populated.
-- ---------------------------------------------------------------------------

local PATIENT_TEMPLATE = [[
{
    "resourceType": "Patient",
    "id": null,
    "meta": {
        "versionId": null,
        "lastUpdated": null,
        "source": null,
        "profile": [null]
    },
    "active": null,
    "identifier": [
        {
            "system": null,
            "value": null,
            "use": null,
            "type": {
                "coding": [{"system": null, "code": null, "display": null}],
                "text": null
            }
        }
    ],
    "name": [
        {
            "use": null,
            "family": null,
            "given": [null],
            "prefix": [null],
            "suffix": [null],
            "text": null
        }
    ],
    "telecom": [
        {
            "system": null,
            "value": null,
            "use": null
        }
    ],
    "gender": null,
    "birthDate": null,
    "deceasedBoolean": null,
    "address": [
        {
            "use": null,
            "type": null,
            "text": null,
            "line": [null],
            "city": null,
            "state": null,
            "postalCode": null,
            "country": null
        }
    ],
    "maritalStatus": {
        "coding": [{"system": null, "code": null, "display": null}],
        "text": null
    },
    "communication": [
        {
            "language": {
                "coding": [{"system": null, "code": null, "display": null}],
                "text": null
            },
            "preferred": null
        }
    ],
    "managingOrganization": {
        "reference": null,
        "display": null
    }
}
]]

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {}

-- Return a fresh parsed copy of the Patient template.
function M.template()
   return linkiir.json.parse(PATIENT_TEMPLATE)
end

-- Map inbound patient data onto the template.
--
-- The input is expected to be a JSON object with top-level patient fields:
--   given, family, gender, birthDate, phone, email, city, state, postalCode,
--   addressLine, country, identifier_system, identifier_value, active
--
-- Fields that are absent or empty in the input are left as null and removed
-- by the clean pass.
local function mapPatient(Template, Input)
   -- Name
   if Input.family or Input.given then
      Template.name[1].use = 'official'
      Template.name[1].family = Input.family
      Template.name[1].given[1] = Input.given
   end

   -- Demographics
   if Input.gender then
      Template.gender = Input.gender
   end
   if Input.birthDate then
      Template.birthDate = Input.birthDate
   end

   -- Active flag
   if Input.active ~= nil then
      Template.active = Input.active
   end

   -- Telecom
   local telecomIdx = 0
   if Input.phone then
      telecomIdx = telecomIdx + 1
      Template.telecom[telecomIdx] = {
         system = 'phone',
         value  = Input.phone,
         use    = 'home',
      }
   end
   if Input.email then
      telecomIdx = telecomIdx + 1
      Template.telecom[telecomIdx] = {
         system = 'email',
         value  = Input.email,
         use    = 'home',
      }
   end
   if telecomIdx == 0 then
      Template.telecom = linkiir.json.null
   end

   -- Address
   if Input.city or Input.state or Input.postalCode or Input.addressLine or Input.country then
      Template.address[1].use = 'home'
      Template.address[1].city = Input.city
      Template.address[1].state = Input.state
      Template.address[1].postalCode = Input.postalCode
      Template.address[1].country = Input.country
      if Input.addressLine then
         Template.address[1].line[1] = Input.addressLine
      end
   end

   -- Identifier
   if Input.identifier_system or Input.identifier_value then
      Template.identifier[1].system = Input.identifier_system
      Template.identifier[1].value = Input.identifier_value
      Template.identifier[1].use = 'usual'
   end

   Template.resourceType = 'Patient'
   return Template
end

-- Build a FHIR Patient resource from an inbound JSON message.
--
-- Returns the serialised JSON string, or nil plus an error table.
function M.fromData(Data)
   if Data == nil or Data == '' then
      return nil, { code = 'INPUT_ERROR', message = 'no input data received' }
   end

   local ok, Input = pcall(linkiir.json.parse, Data)
   if not ok then
      return nil, { code = 'PARSE_ERROR', message = 'input is not valid JSON: ' .. tostring(Input) }
   end

   if type(Input) ~= 'table' then
      return nil, { code = 'INPUT_ERROR', message = 'input must be a JSON object' }
   end

   local Template = M.template()
   mapPatient(Template, Input)
   Clean.removeNulls(Template)

   return linkiir.json.serialize(Template)
end

return M
