-- ---------------------------------------------------------------------------
-- cerner_fhir_http - the request path every FHIR call goes through
--
-- Attaches the bearer token, builds the resource URL, sends the request, and
-- turns whatever Cerner returns into one predictable pair:
--
--    Result        - the parsed resource or Bundle
--    nil, Err      - Err is { code=, message= } plus optional context
--
-- Cerner FHIR responses follow the same patterns as Epic:
--
--   * An OperationOutcome resource can arrive with HTTP 200. Cerner uses it
--     for business-level problems such as a search with no usable parameters.
--   * A successful create answers 201 with an empty body and puts the new
--     resource id in the Location header.
-- ---------------------------------------------------------------------------

local Auth = require 'cerner_fhir_auth'

local M = {}

-- Verbs whose parameters belong in the query string. Everything else sends a
-- JSON body.
local QUERY_VERBS = {
   get     = true,
   head    = true,
   delete  = true,
   options = true,
}

-- True when a parsed body is an OperationOutcome, in either the bare or the
-- wrapped form Cerner can return.
local function isOperationOutcome(Parsed)
   if type(Parsed) ~= 'table' then return false end
   if Parsed.resourceType == 'OperationOutcome' then return true end
   if type(Parsed.OperationOutcome) == 'table' and Parsed.OperationOutcome.issue then
      return true
   end
   return false
end

-- Collapse an OperationOutcome's issues into one readable sentence, so a
-- failure is diagnosable from the log line without unpacking the resource.
local function outcomeText(Outcome)
   local Issues = Outcome.issue
      or (type(Outcome.OperationOutcome) == 'table' and Outcome.OperationOutcome.issue)
   if type(Issues) ~= 'table' then return nil end

   local Messages = {}
   for _, Issue in ipairs(Issues) do
      local Text = (type(Issue.details) == 'table' and Issue.details.text)
         or Issue.diagnostics
         or Issue.code
      if Text then Messages[#Messages + 1] = tostring(Text) end
   end

   if #Messages == 0 then return nil end
   return table.concat(Messages, '; ')
end

-- Merge caller headers with the ones this module controls. Authorization is
-- applied last so a caller cannot accidentally replace it.
local function buildHeaders(CallerHeaders, Token)
   local Headers = {}
   for Key, Value in pairs(CallerHeaders or {}) do
      Headers[Key] = Value
   end
   Headers['Accept'] = Headers['Accept'] or 'application/fhir+json'
   Headers['Authorization'] = 'Bearer ' .. Token
   return Headers
end

-- Interpret a response with no body. A 2xx here is Cerner's create success.
local function readEmptyBody(Response)
   if Response.code >= 200 and Response.code < 300 then
      local Location = Response.headers
         and (Response.headers.Location or Response.headers.location)
      return {
         created  = true,
         code     = Response.code,
         location = Location,
      }
   end

   return nil, {
      code    = 'HTTP_' .. tostring(Response.code),
      message = 'Cerner returned HTTP ' .. tostring(Response.code) .. ' with an empty body',
   }
end

-- Parse a response body and classify it as success or failure.
local function readBody(Response)
   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok then
      return nil, {
         code      = 'PARSE_ERROR',
         message   = 'Cerner response was not valid JSON',
         http_code = Response.code,
         body      = Response.body,
      }
   end

   if isOperationOutcome(Parsed) then
      return nil, {
         code      = 'FHIR_OPERATION_OUTCOME',
         message   = outcomeText(Parsed) or 'Cerner returned an OperationOutcome',
         http_code = Response.code,
         outcome   = Parsed,
      }
   end

   if Response.code < 200 or Response.code >= 300 then
      return nil, {
         code      = 'HTTP_' .. tostring(Response.code),
         message   = 'Cerner returned HTTP ' .. tostring(Response.code),
         http_code = Response.code,
         body      = Parsed,
      }
   end

   return Parsed
end

-- Send one FHIR request.
--
--   T.method     - HTTP verb, defaults to 'get'
--   T.api        - resource path below the base URL, e.g. 'Patient/12345'
--   T.parameters - query table for GET-like verbs, JSON body for the rest
--   T.headers    - extra headers
--   T.live       - overrides the client's live flag for this call
function M.request(Client, T)
   local Token, AuthErr = Auth.ensure(Client)
   if not Token then return nil, AuthErr end

   local Method = tostring(T.method or 'get'):lower()
   local SendRequest = linkiir.link.web[Method]
   if not SendRequest then
      error("cerner_fhir_http.request: unsupported HTTP method '" .. Method .. "'")
   end

   local Headers = buildHeaders(T.headers, Token)

   -- A per-call live flag wins over the client's; both default to true.
   local Live = T.live
   if Live == nil then Live = Client.live end
   if Live == nil then Live = true end

   local Request = {
      url       = Client.base_url .. tostring(T.api),
      headers   = Headers,
      timeout   = Client.timeout,
      verifyTls = Client.verify_tls,
      live      = Live,
   }

   if QUERY_VERBS[Method] then
      Request.params = T.parameters
   elseif T.parameters ~= nil then
      Request.body = linkiir.json.serialize(T.parameters)
      Headers['Content-Type'] = 'application/fhir+json'
   end

   linkiir.log.debug('cerner_fhir ' .. Method:upper() .. ' ' .. Request.url)

   local Response, WebErr = SendRequest(Request)
   if not Response then
      return nil, WebErr or {
         code    = 'REQUEST_FAILED',
         message = Method:upper() .. ' ' .. Request.url .. ' failed',
      }
   end

   -- With live = false nothing was sent, so there is no body to interpret.
   if Response.simulated then
      return { simulated = true, code = 0 }
   end

   if Response.body == nil or Response.body == '' then
      return readEmptyBody(Response)
   end

   return readBody(Response)
end

return M
