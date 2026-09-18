-- ---------------------------------------------------------------------------
-- hapi_fhir_http - the request path every FHIR call goes through
--
-- Internal module. Applies authentication, builds the URL, sends the request,
-- and turns whatever the server returns into one predictable pair:
--
--    Result        - the parsed resource or Bundle
--    nil, Err      - Err is { code=, message= } plus optional context
--
-- Two things worth knowing, because both look like success at the HTTP layer
-- and are reported as failures here:
--
--   * An OperationOutcome can arrive with HTTP 200. FHIR servers use it for
--     business-level problems such as an unsupported search parameter.
--   * A create answers 201, and HAPI returns the created resource in the body
--     while some deployments return nothing. Both are handled.
--
-- URL construction differs from the Epic and Cerner libraries on purpose. Those
-- servers expose FHIR under a fixed path below a host, so their client appends
-- `api/FHIR/<version>/`. Here the operator supplies the *FHIR base URL* itself -
-- `https://hapi.fhir.org/baseR4`, or whatever Smile issued - so the request path
-- is the base plus the resource and nothing else. Inventing a path segment would
-- break every deployment that does not happen to match it.
-- ---------------------------------------------------------------------------

local Auth = require 'hapi_fhir_auth'

local M = {}

-- Verbs whose parameters belong in the query string. Everything else sends a
-- JSON body.
local QUERY_VERBS = {
   get     = true,
   head    = true,
   delete  = true,
   options = true,
}

-- The media type a FHIR release is negotiated with. FHIR defines a `fhirVersion`
-- parameter on the JSON media type for servers that host more than one release.
--
-- Sent because it is the standards-correct way to ask, but note it is advisory:
-- the public HAPI sandbox accepts `fhirVersion=5.0` against its R4 base and
-- answers R4 anyway. Treat the CapabilityStatement as the authority on what a
-- server actually speaks - see Client:capabilities().
local VERSION_MEDIA = {
   R4 = '4.0',
   R5 = '5.0',
}

local function err(Code, Message, Extra)
   local E = { code = Code, message = Message }
   for K, V in pairs(Extra or {}) do E[K] = V end
   return E
end

-- True when a parsed body is an OperationOutcome.
local function isOperationOutcome(Parsed)
   return type(Parsed) == 'table' and Parsed.resourceType == 'OperationOutcome'
end

-- Collapse an OperationOutcome's issues into one readable sentence, so a failure
-- is diagnosable from the log line without unpacking the resource.
local function outcomeText(Outcome)
   if type(Outcome.issue) ~= 'table' then return nil end
   local Messages = {}
   for _, Issue in ipairs(Outcome.issue) do
      local Text = (type(Issue.details) == 'table' and Issue.details.text)
         or Issue.diagnostics
         or Issue.code
      if Text then Messages[#Messages + 1] = tostring(Text) end
   end
   if #Messages == 0 then return nil end
   return table.concat(Messages, '; ')
end

-- An OperationOutcome whose issues are all informational or warnings is not a
-- failure. A successful $validate answers exactly that, and so does a delete on
-- some servers.
local function outcomeIsFatal(Outcome)
   if type(Outcome.issue) ~= 'table' then return true end
   for _, Issue in ipairs(Outcome.issue) do
      local Severity = tostring(Issue.severity or 'error')
      if Severity == 'error' or Severity == 'fatal' then return true end
   end
   return false
end

-- Merge caller headers with the ones this module controls. Authorization is
-- applied last so a caller cannot accidentally replace it.
local function buildHeaders(Client, CallerHeaders, AuthHeader)
   local Headers = {}
   for Key, Value in pairs(CallerHeaders or {}) do
      Headers[Key] = Value
   end
   if not Headers['Accept'] then
      local Media = VERSION_MEDIA[Client.version]
      Headers['Accept'] = Media
         and ('application/fhir+json; fhirVersion=' .. Media)
         or 'application/fhir+json'
   end
   if AuthHeader then Headers['Authorization'] = AuthHeader end
   return Headers
end

-- Interpret a response with no body. A 2xx here is a create or delete that
-- returned nothing, which is legal.
local function readEmptyBody(Response)
   if Response.code >= 200 and Response.code < 300 then
      local Location = Response.headers
         and (Response.headers.Location or Response.headers.location)
      return {
         created  = Response.code == 201 or nil,
         code     = Response.code,
         location = Location,
      }
   end
   return nil, err('HTTP_' .. tostring(Response.code),
      'FHIR server returned HTTP ' .. tostring(Response.code) .. ' with an empty body',
      { http_code = Response.code })
end

-- Parse a response body and classify it as success or failure.
local function readBody(Response)
   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok then
      -- Requests pin Accept to application/fhir+json, so a body that is not JSON
      -- is a genuine fault rather than an alternate format to handle. An HTML
      -- error page from a reverse proxy is the usual cause, so a snippet of the
      -- body is carried along - it is what identifies the proxy.
      return nil, err('PARSE_ERROR', 'FHIR response was not valid JSON',
         { http_code = Response.code, body = tostring(Response.body):sub(1, 300) })
   end

   if isOperationOutcome(Parsed) then
      if outcomeIsFatal(Parsed) then
         return nil, err('FHIR_OPERATION_OUTCOME',
            outcomeText(Parsed) or 'FHIR server returned an OperationOutcome',
            { http_code = Response.code, outcome = Parsed })
      end
      -- Informational only: hand it back as the result.
      return Parsed
   end

   if Response.code < 200 or Response.code >= 300 then
      return nil, err('HTTP_' .. tostring(Response.code),
         'FHIR server returned HTTP ' .. tostring(Response.code),
         { http_code = Response.code, body = Parsed })
   end

   return Parsed
end

-- Send one FHIR request.
--
--   T.method     - HTTP verb, defaults to 'get'
--   T.api        - path below the FHIR base, e.g. 'Patient/123'
--   T.url        - absolute URL, used instead of api. Paging uses this: a
--                  Bundle's next link is absolute and on a different path from
--                  the search that produced it, so it has to be followed
--                  verbatim rather than rebuilt.
--   T.parameters - query table for GET-like verbs, JSON body for the rest
--   T.headers    - extra headers
--   T.live       - overrides the client's live flag for this call
function M.request(Client, T)
   local AuthHeader, AuthErr = Auth.header(Client)
   if AuthErr then return nil, AuthErr end

   local Method = tostring(T.method or 'get'):lower()
   local SendRequest = linkiir.link.web[Method]
   if not SendRequest then
      error("hapi_fhir_http.request: unsupported HTTP method '" .. Method .. "'")
   end

   local Headers = buildHeaders(Client, T.headers, AuthHeader)

   -- A per-call live flag wins over the client's; both default to true.
   local Live = T.live
   if Live == nil then Live = Client.live end
   if Live == nil then Live = true end

   local Url = T.url
   if not Url or Url == '' then
      Url = Client.base_url .. tostring(T.api)
   end

   local Request = {
      url       = Url,
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

   linkiir.log.debug('hapi_fhir ' .. Method:upper() .. ' ' .. Request.url)

   local Response, WebErr = SendRequest(Request)
   if not Response then
      return nil, err('REQUEST_FAILED',
         Method:upper() .. ' ' .. Request.url .. ' failed: ' .. tostring(WebErr))
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
