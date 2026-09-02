-- ---------------------------------------------------------------------------
-- fhir_profiling_web - HTTP request routing for the profiling tool
--
-- Internal module. Handles incoming web requests by routing to the
-- appropriate action: root page (HTML list), resource template (JSON),
-- or error response.
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
This tool creates JSON templates of FHIR resources and types. The current version is <b>]]

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

local WEB_FOOTER = [[
</ul>
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

local function createList(Items)
   local Parts = {}
   for i = 1, #Items do
      Parts[#Parts + 1] = '<li><a href="?resource='
         .. Items[i]:lower() .. '">' .. Items[i] .. '</a></li>'
   end
   return table.concat(Parts, '\n')
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
      respondJson(
         linkiir.json.serialize({ error = 'Unrecognized endpoint: ' .. Location }),
         404
      )
      return
   end

   -- No query params: serve the HTML index page
   if not Params.resource then
      local SortedList = Client:sortedList()
      local H = {
         WEB_HEADER,
         Client.version,
         WEB_RESOURCES_HEADER,
         createList(SortedList.Resources),
         WEB_TYPES_HEADER,
         createList(SortedList.Types),
         WEB_FOOTER,
      }
      linkiir.link.web.respond{
         body        = table.concat(H),
         contentType = 'text/html',
      }
      return
   end

   -- Query param ?resource=<name>: serve a JSON resource template
   local ResourceName = Client:resolveResourceName(Params.resource)
   if ResourceName then
      local Template = Client:createResource(ResourceName)
      if Template then
         respondJson(linkiir.json.serialize(Template))
      else
         respondJson(
            linkiir.json.serialize({ error = 'Failed to generate template for: ' .. ResourceName }),
            500
         )
      end
   else
      respondJson(
         linkiir.json.serialize({ error = 'Unrecognized resource/type: ' .. Params.resource }),
         404
      )
   end
end

return M
