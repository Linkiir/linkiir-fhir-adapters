-- ---------------------------------------------------------------------------
-- fhir_creator - helpers for hand-building a FHIR resource in main.lua
--
--   package.path = linkiir.sys.nodeDir() .. '/?/init.lua;' .. package.path
--   local Fhir = require 'fhir_creator'
--
--   local Patient = Fhir.new('Patient')
--   Fhir.addIdentifier(Patient, Input.identifier_system, Input.identifier_value)
--   Fhir.addName(Patient, Input.given, Input.family)
--   Patient.gender = Fhir.gender(Input.gender)
--   linkiir.flow.push{ data = Fhir.toJson(Patient) }
--
-- The helpers append a repeating element only when its inputs are present, so
-- the resource is built from populated fields alone. There is no null cleaner:
-- an absent, empty, or JSON-null input is simply never written. Call an add*
-- helper again to add a second name, identifier, or telecom.
--
-- This is a construction aid, not a validator. It does not enforce a FHIR
-- version, a resource's required fields, or a customer profile - the FHIR
-- Validator, pointed at a server of the matching FHIR version, is the authority.
--
-- Arrays are tagged with linkiir.json.array so a single-element array (a lone
-- name, one given name) serializes as a JSON array, never as an object.
-- ---------------------------------------------------------------------------

local Fhir = {}

-- A value worth writing: not nil, not the empty string, and not the JSON null
-- sentinel that linkiir.json.parse produces for an inbound JSON null. Without
-- the sentinel check, a JSON `null` would read as a table and be treated as
-- present, writing an invalid value.
local function present(value)
   return value ~= nil
      and value ~= ''
      and value ~= linkiir.json.null
end

-- A tagged single-item array, so it serializes as [item] rather than {item}.
local function arrayOf(item)
   return linkiir.json.array{ item }
end

function Fhir.new(resourceType)
   assert(present(resourceType), 'FHIR resource type is required')
   return { resourceType = resourceType }
end

-- Add an identifier { system, value }. Both are required together: an
-- identifier with only a system or only a value is not a usable identifier.
function Fhir.addIdentifier(resource, system, value)
   if not present(system) and not present(value) then
      return
   end
   assert(present(system) and present(value),
      'Identifier requires both system and value')
   resource.identifier = resource.identifier or linkiir.json.array{}
   table.insert(resource.identifier, linkiir.json.object{ system = system, value = value })
end

-- Add a HumanName. `given` may be a single string or a list of strings; either
-- serializes as name.given = [ ... ]. At least one of given/family is required.
function Fhir.addName(resource, given, family)
   if not present(given) and not present(family) then
      return
   end
   local name = linkiir.json.object{}
   if present(given) then
      if type(given) == 'table' then
         local list = linkiir.json.array{}
         for i = 1, #given do
            if present(given[i]) then list[#list + 1] = given[i] end
         end
         if #list > 0 then name.given = list end
      else
         name.given = arrayOf(given)
      end
   end
   if present(family) then
      name.family = family
   end
   if next(name) ~= nil then
      resource.name = resource.name or linkiir.json.array{}
      table.insert(resource.name, name)
   end
end

-- Add a telecom (ContactPoint). Only phone and email are supported here; other
-- valid FHIR systems can be added as the need arises.
function Fhir.addTelecom(resource, system, value)
   if not present(value) then
      return
   end
   assert(system == 'phone' or system == 'email', 'Unsupported telecom system: ' .. tostring(system))
   resource.telecom = resource.telecom or linkiir.json.array{}
   table.insert(resource.telecom, linkiir.json.object{ system = system, value = value })
end

-- Add an Address from a table of parts { addressLine, city, state, postalCode,
-- country }. Only the parts that are present are written; an all-empty input
-- adds nothing.
function Fhir.addAddress(resource, input)
   if type(input) ~= 'table' then
      return
   end
   local address = linkiir.json.object{}
   if present(input.addressLine) then address.line = arrayOf(input.addressLine) end
   if present(input.city) then address.city = input.city end
   if present(input.state) then address.state = input.state end
   if present(input.postalCode) then address.postalCode = input.postalCode end
   if present(input.country) then address.country = input.country end
   if next(address) ~= nil then
      resource.address = resource.address or linkiir.json.array{}
      table.insert(resource.address, address)
   end
end

-- Normalize a common administrative-gender code to a FHIR value. Returns nil
-- for an absent input (so the caller can leave gender unset), and asserts on a
-- value it does not recognize rather than inventing one.
function Fhir.gender(value)
   if not present(value) then
      return nil
   end
   local values = {
      M = 'male', F = 'female', O = 'other', U = 'unknown',
      male = 'male', female = 'female', other = 'other', unknown = 'unknown',
   }
   local result = values[value]
   assert(result ~= nil, 'Unsupported administrative gender: ' .. tostring(value))
   return result
end

-- Serialize the completed resource to a compact JSON string.
function Fhir.toJson(resource)
   assert(type(resource) == 'table', 'FHIR resource must be an object')
   assert(present(resource.resourceType), 'Missing resourceType')
   return linkiir.json.serialize(resource)
end

return Fhir
