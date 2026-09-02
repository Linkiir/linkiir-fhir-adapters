-- ---------------------------------------------------------------------------
-- athena_health_http - the request path every API call goes through
--
-- Attaches the bearer token, builds the full URL, sends the request, and
-- turns whatever Athena returns into one predictable pair:
--
--    Result        - the parsed JSON response
--    nil, Err      - Err is { code=, message= } plus optional context
--
-- Athena exposes two distinct APIs:
--   * Proprietary REST: v1/<practice_id>/patients, etc.
--   * FHIR R4: /fhir/r4/Patient, etc.
--
-- Both use the same bearer token and base URL. The caller provides the full
-- API path below the base URL.
-- ---------------------------------------------------------------------------

local Auth = require 'athena_health_auth'

local M = {}

-- Verbs whose parameters belong in the query string. Everything else sends a
-- form-encoded body (Athena REST API uses form-encoded POSTs).
local QUERY_VERBS = {
   get     = true,
   head    = true,
   delete  = true,
   options = true,
}

-- True when a parsed body is a FHIR OperationOutcome.
local function isOperationOutcome(Parsed)
   if type(Parsed) ~= 'table' then return false end
   if Parsed.resourceType == 'OperationOutcome' then return true end
   return false
end

-- Collapse an OperationOutcome's issues into one readable sentence.
local function outcomeText(Outcome)
   local Issues = Outcome.issue
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

-- Merge caller headers with the ones this module controls.
local function buildHeaders(CallerHeaders, Token)
   local Headers = {}
   for Key, Value in pairs(CallerHeaders or {}) do
      Headers[Key] = Value
   end
   Headers['Accept'] = Headers['Accept'] or 'application/json'
   Headers['Authorization'] = 'Bearer ' .. Token
   return Headers
end

-- Percent-encode a flat table as application/x-www-form-urlencoded.
local function formEncode(Params)
   local Parts = {}
   for Key, Value in pairs(Params) do
      Parts[#Parts + 1] = linkiir.codec.uri.encode(tostring(Key))
         .. '=' .. linkiir.codec.uri.encode(tostring(Value))
   end
   return table.concat(Parts, '&')
end

-- Parse a response body and classify it as success or failure.
local function readBody(Response)
   local Ok, Parsed = pcall(linkiir.json.parse, Response.body)
   if not Ok then
      return nil, {
         code      = 'PARSE_ERROR',
         message   = 'Athena response was not valid JSON',
         http_code = Response.code,
         body      = Response.body,
      }
   end

   -- Athena REST API error shape: { error: "..." }
   if type(Parsed) == 'table' and Parsed.error then
      return nil, {
         code      = 'API_ERROR',
         message   = tostring(Parsed.error),
         http_code = Response.code,
         body      = Parsed,
      }
   end

   -- FHIR OperationOutcome
   if isOperationOutcome(Parsed) then
      return nil, {
         code      = 'FHIR_OPERATION_OUTCOME',
         message   = outcomeText(Parsed) or 'Athena returned an OperationOutcome',
         http_code = Response.code,
         outcome   = Parsed,
      }
   end

   if Response.code < 200 or Response.code >= 300 then
      return nil, {
         code      = 'HTTP_' .. tostring(Response.code),
         message   = 'Athena returned HTTP ' .. tostring(Response.code),
         http_code = Response.code,
         body      = Parsed,
      }
   end

   return Parsed
end

-- Send one API request.
--
--   T.method     - HTTP verb, defaults to 'get'
--   T.api        - path below the base URL, e.g. 'v1/1128700/patients'
--   T.parameters - query table for GET-like verbs, form-encoded body for POST
--   T.headers    - extra headers
--   T.live       - overrides the client's live flag for this call
function M.request(Client, T)
   local Token, AuthErr = Auth.ensure(Client)
   if not Token then return nil, AuthErr end

   local Method = tostring(T.method or 'get'):lower()
   local SendRequest = linkiir.link.web[Method]
   if not SendRequest then
      error("athena_health_http.request: unsupported HTTP method '" .. Method .. "'")
   end

   local Headers = buildHeaders(T.headers, Token)

   -- A per-call live flag wins over the client's; both default to true.
   local Live = T.live
   if Live == nil then Live = Client.live end
   if Live == nil then Live = true end

   local Url = Client.base_url .. tostring(T.api)

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
      -- Athena REST API expects form-encoded POST bodies
      Request.body = formEncode(T.parameters)
      Headers['Content-Type'] = 'application/x-www-form-urlencoded'
   end

   linkiir.log.debug('athena_health ' .. Method:upper() .. ' ' .. Url)

   local Response, WebErr = SendRequest(Request)
   if not Response then
      return nil, WebErr or {
         code    = 'REQUEST_FAILED',
         message = Method:upper() .. ' ' .. Url .. ' failed',
      }
   end

   -- With live = false nothing was sent, so there is no body to interpret.
   if Response.simulated then
      return { simulated = true, code = 0 }
   end

   -- Check for rate limiting
   if Response.headers then
      local Remaining = Response.headers['X-RateLimit-Remaining']
         or Response.headers['x-ratelimit-remaining']
      if Remaining and tonumber(Remaining) and tonumber(Remaining) < 5 then
         linkiir.log.warn('athena_health: limited API calls remaining: ' .. tostring(Remaining))
      end
   end

   if Response.body == nil or Response.body == '' then
      if Response.code >= 200 and Response.code < 300 then
         return { code = Response.code }
      end
      return nil, {
         code    = 'HTTP_' .. tostring(Response.code),
         message = 'Athena returned HTTP ' .. tostring(Response.code) .. ' with an empty body',
      }
   end

   return readBody(Response)
end

return M
