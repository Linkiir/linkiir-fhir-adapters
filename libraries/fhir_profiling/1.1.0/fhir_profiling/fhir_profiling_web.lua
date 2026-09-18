-- ---------------------------------------------------------------------------
-- fhir_profiling_web - HTTP request routing for the profiling tool
--
-- Internal module. Routes an inbound web request:
--
--   GET  /                          the HTML index (resource + type lists)
--   GET  /?resource=<name>          a JSON template for a resource/type (1.0.0)
--   GET  /?action=elements&base=<R> the constrainable elements of a base
--                                   resource, as JSON (1.1.0)
--   POST /?action=build             body is a constraint spec; returns the
--                                   generated differential StructureDefinition
--                                   as JSON (1.1.0)
--   POST /?action=import            body is a StructureDefinition; returns it
--                                   parsed with its editable constraints (1.1.0)
--
-- The authoring routes (1.1.0) let the served UI compose a profile by calling
-- the node's own Lua - the same buildProfile/importProfile a workflow would
-- use - rather than duplicating the logic in browser JavaScript.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- HTML page constants
-- ---------------------------------------------------------------------------
local WEB_HEADER = [[
<html>
<head>
<title>FHIR Profiling Tool</title>
</head>
<body>
<p>
This tool creates JSON templates of FHIR resources and types, and authors
constrained profiles. The current version is <b>]]

local WEB_RESOURCES_HEADER = [[
</b>
</p>
<h2>FHIR Resource List</h2>
<ul>
]]

local WEB_TYPES_HEADER = [[
</ul>
<h2>FHIR Type List</h2>
<ul>
]]

local WEB_PROFILE_SECTION = [[
</ul>
<h2>Profile Designer</h2>
<p>Author a constrained profile from a base resource. The API:</p>
<ul>
<li><code>GET  ?action=elements&amp;base=Patient</code> &mdash; the elements you can constrain</li>
<li><code>POST ?action=build</code> &mdash; body is a constraint spec, returns a differential StructureDefinition</li>
<li><code>POST ?action=import</code> &mdash; body is a StructureDefinition, returns it with editable constraints</li>
</ul>
<p><em>The Designer produces a FHIR differential. It is not a snapshot and is
not a conformance check &mdash; validate the result with the FHIR Validator, or a
server that supports StructureDefinition/$validate.</em></p>
]]

local WEB_FOOTER = [[
</body>
</html>
]]

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
local function respondJson(Body, Code)
   linkiir.link.web.respond{
      body        = Body,
      contentType = 'application/json',
      code        = Code or 200,
   }
end

local function respondError(Message, Code)
   respondJson(linkiir.json.serialize({ error = Message }), Code or 400)
end

local function createList(Items)
   local Parts = {}
   for i = 1, #Items do
      Parts[#Parts + 1] = '<li><a href="?resource='
         .. Items[i]:lower() .. '">' .. Items[i] .. '</a></li>'
   end
   return table.concat(Parts, '\n')
end

-- The request body, from whichever field the inbound-request table exposes it
-- under. Kept tolerant because a POST body may arrive as .body or as the raw
-- Data string depending on how the request was delivered.
local function requestBody(Req, Data)
   if type(Req.body) == 'string' and Req.body ~= '' then return Req.body end
   if type(Req.data) == 'string' and Req.data ~= '' then return Req.data end
   if type(Data) == 'string' and Data ~= '' then return Data end
   return nil
end

-- ---------------------------------------------------------------------------
-- Authoring actions (1.1.0)
-- ---------------------------------------------------------------------------
local function serveElements(Client, Params)
   local Base = Params.base or Params.resource
   if not Base or Base == '' then
      respondError('action=elements needs a base resource, e.g. ?action=elements&base=Patient')
      return
   end
   -- Accept the case-insensitive name the resource list uses.
   local Resolved = Client:resolveResourceName(Base) or Base
   local Elements, ElErr = Client:baseElements(Resolved)
   if not Elements then
      respondError(ElErr or ('unknown base resource: ' .. Base), 404)
      return
   end
   respondJson(linkiir.json.serialize({ base = Resolved, elements = Elements }))
end

local function serveBuild(Client, Body)
   if not Body then
      respondError('action=build needs a JSON constraint spec in the request body')
      return
   end
   local Ok, Spec = pcall(linkiir.json.parse, Body)
   if not Ok or type(Spec) ~= 'table' then
      respondError('constraint spec is not valid JSON')
      return
   end
   local Definition, BuildErr = Client:buildProfile(Spec)
   if not Definition then
      respondError(BuildErr.message, 400)
      return
   end
   respondJson(linkiir.json.serialize(Definition))
end

local function serveImport(Client, Body)
   if not Body then
      respondError('action=import needs a StructureDefinition in the request body')
      return
   end
   local Result, ImportErr = Client:importProfile(Body)
   if not Result then
      respondError(ImportErr.message, 400)
      return
   end
   respondJson(linkiir.json.serialize({
      base        = Result.base,
      hasSnapshot = Result.hasSnapshot,
      editable    = Result.editable,
      definition  = Result.definition,
   }))
end

-- ---------------------------------------------------------------------------
-- Public: serve a request
-- ---------------------------------------------------------------------------
local M = {}

function M.serve(Client, Data)
   local Req = linkiir.link.web.request{ data = Data }
   local Location = Req.location or '/'
   local Params = Req.params or {}

   if Location ~= '/' then
      respondError('Unrecognized endpoint: ' .. Location, 404)
      return
   end

   -- Authoring actions (1.1.0), selected by ?action=
   local Action = Params.action
   if Action == 'elements' then
      serveElements(Client, Params)
      return
   elseif Action == 'build' then
      serveBuild(Client, requestBody(Req, Data))
      return
   elseif Action == 'import' then
      serveImport(Client, requestBody(Req, Data))
      return
   elseif Action ~= nil then
      respondError('Unknown action: ' .. tostring(Action), 400)
      return
   end

   -- ?resource=<name>: a JSON resource template (1.0.0 behaviour, unchanged)
   if Params.resource then
      local ResourceName = Client:resolveResourceName(Params.resource)
      if ResourceName then
         local Template = Client:createResource(ResourceName)
         if Template then
            respondJson(linkiir.json.serialize(Template))
         else
            respondError('Failed to generate template for: ' .. ResourceName, 500)
         end
      else
         respondError('Unrecognized resource/type: ' .. Params.resource, 404)
      end
      return
   end

   -- No params: the HTML index (now including the Profile Designer section)
   local SortedList = Client:sortedList()
   local H = {
      WEB_HEADER,
      Client.version,
      WEB_RESOURCES_HEADER,
      createList(SortedList.Resources),
      WEB_TYPES_HEADER,
      createList(SortedList.Types),
      WEB_PROFILE_SECTION,
      WEB_FOOTER,
   }
   linkiir.link.web.respond{
      body        = table.concat(H),
      contentType = 'text/html',
   }
end

return M
