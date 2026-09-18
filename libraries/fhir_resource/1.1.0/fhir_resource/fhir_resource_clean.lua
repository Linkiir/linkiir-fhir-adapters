-- ---------------------------------------------------------------------------
-- fhir_resource_clean - Recursively removes JSON null values from a table
--
-- After mapping inbound data onto a FHIR template, many fields remain as
-- linkiir.json.null. This module strips them so the serialised output contains
-- only populated fields.
--
-- Usage (internal to fhir_resource):
--    local Clean = require 'fhir_resource_clean'
--    Clean.removeNulls(resource)
-- ---------------------------------------------------------------------------

local M = {}

-- Remove all keys whose value is the JSON null sentinel from a table,
-- recursively. Array entries that are null are removed and the array is
-- compacted. Empty sub-tables left behind after cleaning are also removed.
--
-- Operates in place and returns the table for convenience.
function M.removeNulls(T)
   if type(T) ~= 'table' then
      return T
   end

   local jsonNull = linkiir.json.null

   -- Detect whether T is an array (consecutive integer keys starting at 1).
   local isArray = (#T > 0)

   if isArray then
      -- Walk backwards to safely remove entries.
      local i = #T
      while i >= 1 do
         if T[i] == jsonNull then
            table.remove(T, i)
         elseif type(T[i]) == 'table' then
            M.removeNulls(T[i])
            -- Remove empty sub-tables left after cleaning.
            if next(T[i]) == nil then
               table.remove(T, i)
            end
         end
         i = i - 1
      end
   else
      -- Object: remove null-valued keys and recurse into sub-tables.
      for key, value in pairs(T) do
         if value == jsonNull then
            T[key] = nil
         elseif type(value) == 'table' then
            M.removeNulls(value)
            if next(value) == nil then
               T[key] = nil
            end
         end
      end
   end

   return T
end

return M
