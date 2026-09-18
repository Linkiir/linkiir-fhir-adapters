-- ---------------------------------------------------------------------------
-- fhir_profiling_profile - author a derived StructureDefinition
--
-- New in 1.1.0. The 1.0.0 tool reads FHIR definitions and generates a JSON
-- *template* of a resource. This adds the other half: authoring a *profile* -
-- a derived StructureDefinition that constrains a base resource.
--
-- Scope, stated honestly
-- ----------------------
-- What this produces is a **differential**: the list of elements the profile
-- changes, relative to the base resource. That is a genuine FHIR
-- StructureDefinition and it re-parses as one. It is deliberately NOT:
--
--   * a snapshot (the fully-resolved element list). Generating a snapshot means
--     merging the base definition element by element, which is a job for a real
--     FHIR toolchain, not this node.
--   * a conformance certification. Whether the profile is internally consistent
--     and its terminology resolves is a question for a FHIR validator - the
--     FHIR Validator node can POST it to StructureDefinition/$validate.
--
-- So the output is safe to hand to a validator or a server that does its own
-- snapshot generation, and it is honest about being a differential.
-- ---------------------------------------------------------------------------

local Array  = linkiir.json.array
local Object = linkiir.json.object

local M = {}

-- Element paths that exist on the base resource, read from the loaded spec DB.
-- Returns a sorted list of { path=, min=, max=, short= } for the resource's
-- snapshot elements, so a UI can offer real elements to constrain rather than a
-- hand-typed guess. Returns nil plus a message when the base is unknown.
function M.baseElements(Client, BaseResource)
   Client:ensureLoaded()
   local Def = Client.db:get(BaseResource)
   if not Def or not Def.snapshot or type(Def.snapshot.element) ~= 'table' then
      return nil, 'unknown base resource: ' .. tostring(BaseResource)
   end
   local Out = {}
   for _, El in ipairs(Def.snapshot.element) do
      -- The root element is the resource itself; skip it and any slice (path
      -- carrying a ':'), which this MVP does not author.
      if El.path and El.path ~= BaseResource and not El.path:find(':') then
         Out[#Out + 1] = {
            path  = El.path,
            min   = El.min,
            max   = El.max,
            short = El.short,
         }
      end
   end
   return Out
end

-- Whether a path is a real element of the base resource.
function M.elementExists(Client, BaseResource, Path)
   local Elements = M.baseElements(Client, BaseResource)
   if not Elements then return false end
   for _, El in ipairs(Elements) do
      if El.path == Path then return true end
   end
   return false
end

-- Build a differential StructureDefinition from a constraint spec.
--
--   Spec = {
--     canonicalUrl    = 'https://example.org/fhir/StructureDefinition/LabPatient',
--     businessVersion = '1.0.0',
--     name            = 'LabPatient',
--     status          = 'draft',            -- draft|active|retired (default draft)
--     baseResource    = 'Patient',
--     constraints     = {
--       { path='Patient.identifier', min=1 },
--       { path='Patient.name',       min=1, mustSupport=true },
--       { path='Patient.gender',     max='1' },
--     },
--   }
--
-- Returns the StructureDefinition table (tagged for correct JSON shape), or
-- nil plus an error { code=, message= }. Validates the base, the canonical URL,
-- the version, and every constrained path against the loaded spec.
function M.buildProfile(Client, Spec)
   if type(Spec) ~= 'table' then
      return nil, { code = 'INPUT_ERROR', message = 'no profile spec supplied' }
   end
   local Base = Spec.baseResource
   if not Base or Base == '' then
      return nil, { code = 'INPUT_ERROR', message = 'baseResource is required' }
   end
   if not M.baseElements(Client, Base) then
      return nil, { code = 'INPUT_ERROR', message = 'unknown base resource: ' .. tostring(Base) }
   end
   if type(Spec.canonicalUrl) ~= 'string' or not Spec.canonicalUrl:match('^https?://') then
      return nil, { code = 'INPUT_ERROR',
                    message = 'canonicalUrl is required and must be an http(s) URL' }
   end
   if type(Spec.businessVersion) ~= 'string' or Spec.businessVersion == '' then
      return nil, { code = 'INPUT_ERROR', message = 'businessVersion is required' }
   end
   if type(Spec.name) ~= 'string' or not Spec.name:match('^[A-Za-z][A-Za-z0-9_]*$') then
      return nil, { code = 'INPUT_ERROR',
                    message = 'name is required and must be a valid FHIR name '
                       .. '(letter, then letters/digits/underscore)' }
   end
   local Status = Spec.status or 'draft'
   if Status ~= 'draft' and Status ~= 'active' and Status ~= 'retired' then
      return nil, { code = 'INPUT_ERROR', message = 'status must be draft, active or retired' }
   end

   -- The root element is always present in a differential.
   local Elements = { Object{ id = Base, path = Base } }
   local Seen = {}
   for _, C in ipairs(Spec.constraints or {}) do
      local Path = C.path
      if type(Path) ~= 'string' or Path == '' then
         return nil, { code = 'INPUT_ERROR', message = 'each constraint needs a path' }
      end
      if not M.elementExists(Client, Base, Path) then
         return nil, { code = 'INPUT_ERROR',
                       message = 'element not in ' .. Base .. ': ' .. Path }
      end
      if Seen[Path] then
         return nil, { code = 'INPUT_ERROR', message = 'duplicate constraint on ' .. Path }
      end
      Seen[Path] = true

      local El = Object{ id = Path, path = Path }
      if C.min ~= nil then
         local Min = tonumber(C.min)
         if not Min or Min < 0 or Min ~= math.floor(Min) then
            return nil, { code = 'INPUT_ERROR', message = 'min for ' .. Path .. ' must be a non-negative integer' }
         end
         El.min = Min
      end
      if C.max ~= nil and C.max ~= '' then
         -- FHIR max is a string: a non-negative integer or '*'.
         if C.max ~= '*' and not tostring(C.max):match('^%d+$') then
            return nil, { code = 'INPUT_ERROR', message = "max for " .. Path .. " must be a whole number or '*'" }
         end
         El.max = tostring(C.max)
      end
      if C.mustSupport == true then El.mustSupport = true end
      Elements[#Elements + 1] = El
   end

   if #Elements == 1 then
      return nil, { code = 'INPUT_ERROR',
                    message = 'a profile needs at least one constraint' }
   end

   return Object{
      resourceType   = 'StructureDefinition',
      url            = Spec.canonicalUrl,
      version        = Spec.businessVersion,
      name           = Spec.name,
      status         = Status,
      fhirVersion    = Client.version or '4.0.1',
      kind           = 'resource',
      abstract       = false,
      type           = Base,
      baseDefinition = 'http://hl7.org/fhir/StructureDefinition/' .. Base,
      derivation     = 'constraint',
      differential   = Object{ element = Array(Elements) },
   }
end

-- Parse and lightly check an imported StructureDefinition. Preserves the whole
-- resource verbatim (including snapshot and any construct this tool does not
-- itself author), and surfaces the editable differential constraints alongside.
-- Returns { definition=, editable= } or nil plus an error.
function M.importProfile(Json)
   if type(Json) ~= 'string' or Json == '' then
      return nil, { code = 'INPUT_ERROR', message = 'no StructureDefinition JSON supplied' }
   end
   local Ok, Def = pcall(linkiir.json.parse, Json)
   if not Ok or type(Def) ~= 'table' then
      return nil, { code = 'PARSE_ERROR', message = 'import is not valid JSON' }
   end
   if Def.resourceType ~= 'StructureDefinition' then
      return nil, { code = 'INPUT_ERROR',
                    message = 'import is not a StructureDefinition (resourceType='
                       .. tostring(Def.resourceType) .. ')' }
   end

   -- Surface the differential constraints as an editable list; leave the full
   -- resource untouched so re-export loses nothing this tool cannot model.
   local Editable = {}
   if type(Def.differential) == 'table' and type(Def.differential.element) == 'table' then
      for _, El in ipairs(Def.differential.element) do
         if El.path and El.path ~= Def.type then
            Editable[#Editable + 1] = {
               path        = El.path,
               min         = El.min,
               max         = El.max,
               mustSupport = El.mustSupport,
            }
         end
      end
   end

   return { definition = Def, editable = Editable, base = Def.type,
            hasSnapshot = type(Def.snapshot) == 'table' }
end

return M
