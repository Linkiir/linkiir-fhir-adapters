-- ---------------------------------------------------------------------------
-- fhir_profiling_create - Generate a FHIR resource template
--
-- Internal module. Given a profile database and a resource name, builds a
-- Lua table representing the resource with all leaf fields set to
-- linkiir.json.null, suitable for serialisation as a template.
-- ---------------------------------------------------------------------------

-- Elements that should not recurse into their children to avoid infinite loops
local STOP_POINTS = {
   Extension  = { extension = true },
   Identifier = { assigner = true },
   Reference  = { identifier = true },
}

-- FHIR 4.0.0 uses full URIs for some primitive types
local HTTP_ID_REPLACEMENTS = {
   ['http://hl7.org/fhirpath/System.String'] = 'string',
   ['http://hl7.org/fhirpath/System.Date']   = 'dateTime',
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function getElementKeys(ElementId)
   local Keys = {}
   for Part in ElementId:gmatch('[^.]+') do
      Keys[#Keys + 1] = Part
   end
   table.remove(Keys, 1) -- remove resource type prefix
   return Keys
end

local function getReferenceElement(Db, Element)
   local ReferenceId = Element.contentReference:match('#(.+)')
   local ReferenceResource = ReferenceId:match('^([^.]+)')
   Db:listResourceTypes(ReferenceId)
   local Resource = Db:get(ReferenceResource)
   if not Resource or not Resource.snapshot then
      return nil
   end
   for i = 1, #Resource.snapshot.element do
      if Resource.snapshot.element[i].id == ReferenceId then
         return Resource.snapshot.element[i]
      end
   end
   return nil
end

local function getElementTypeAndId(Db, Element)
   if Element.type == nil and Element.contentReference then
      local RefElement = getReferenceElement(Db, Element)
      if RefElement then
         Element = RefElement
      end
   end

   local Id
   if Element.type and Element.type[1] and Element.type[1].code then
      Id = Element.type[1].code
   elseif Element.type and Element.type[1] and Element.type[1]['_code'] then
      local Keys = getElementKeys(Element.id)
      Id = Keys[1]
   end

   if not Id then
      return nil, nil
   end

   Id = HTTP_ID_REPLACEMENTS[Id] or Id

   local TypeList = Db:listResourceTypes(Id)
   local TypeName = TypeList[1]
   if not TypeName then
      return nil, Id
   end
   return TypeName, Id
end

local function capitalize(s)
   return s:sub(1, 1):upper() .. s:sub(2)
end

-- ---------------------------------------------------------------------------
-- Public function
-- ---------------------------------------------------------------------------

local function createResource(Client, ResourceName)
   local Profile = Client.db:get(ResourceName)
   if not Profile or not Profile.snapshot then
      return nil
   end

   local Snapshot = Profile.snapshot.element
   local R = {}

   for i = 1, #Snapshot do
      -- Skip sliced elements (identified by :)
      if not Snapshot[i].id:find(':') then
         local Element = Snapshot[i]
         local Keys = getElementKeys(Element.id)

         if #Keys > 0 and Keys[1] ~= 'contained' then
            local Target = R

            -- Navigate to the nested target
            if #Keys > 1 then
               local NavKeys = {}
               for k = 1, #Keys do NavKeys[k] = Keys[k] end
               while #NavKeys > 1 do
                  if Target[NavKeys[1]] == nil then
                     Target[NavKeys[1]] = {}
                  end
                  local NextTarget = Target[NavKeys[1]]
                  if type(NextTarget) == 'userdata' then
                     -- Parent is a leaf (json.null); this is a FHIR extension
                     if not Target['_' .. NavKeys[1]] then
                        Target['_' .. NavKeys[1]] = {}
                     end
                     NextTarget = Target['_' .. NavKeys[1]]
                  elseif type(NextTarget) == 'table' and #NextTarget > 0 then
                     NextTarget = NextTarget[1]
                  end
                  Target = NextTarget
                  table.remove(NavKeys, 1)
               end
               Keys = NavKeys
            end

            local ElementType, ElementTypeId = getElementTypeAndId(Client.db, Element)

            if not ElementType then
               -- Unknown type, skip
            elseif Keys[1]:find('%[x%]') then
               -- Choice type: expand into typed variants
               if Element.type then
                  for j = 1, #Element.type do
                     local FieldName = Keys[1]:gsub('%[x%]', capitalize(Element.type[j].code))
                     Target[FieldName] = linkiir.json.null
                  end
               end
            elseif ElementType == 'primitive-type' then
               local TargetValue = linkiir.json.null
               if Element.max == '1' then
                  Target[Keys[1]] = TargetValue
               else
                  Target[Keys[1]] = { TargetValue }
               end
            elseif ElementTypeId == 'BackboneElement' then
               if Element.max == '1' then
                  Target[Keys[1]] = {}
               else
                  Target[Keys[1]] = { {} }
               end
            elseif ElementType == 'complex-type' then
               local ParentName = Element.id:match('^([^.]+)')
               local Stop = (STOP_POINTS[ParentName] and STOP_POINTS[ParentName][Keys[1]])
                  or Keys[1] == 'extension'
               if not Stop then
                  local SubResource = createResource(Client, ElementTypeId)
                  if SubResource then
                     if Element.max == '1' then
                        Target[Keys[1]] = SubResource
                     else
                        Target[Keys[1]] = { SubResource }
                     end
                  end
               end
            elseif ElementType == 'resource' then
               local SubResource = createResource(Client, ElementTypeId)
               if SubResource then
                  if Element.max == '1' then
                     Target[Keys[1]] = SubResource
                  else
                     Target[Keys[1]] = { SubResource }
                  end
               end
            end
         end
      end
   end

   return R
end

return createResource
