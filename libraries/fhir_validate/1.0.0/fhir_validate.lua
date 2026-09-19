-- ---------------------------------------------------------------------------
-- fhir_validate - remote FHIR $validate client
--
-- Validates a FHIR resource against a FHIR server's $validate operation and
-- returns a strict tri-state verdict. Nothing is validated locally: the server
-- is the authority, and a server that cannot answer yields 'unknown' rather
-- than a guess.
--
--    local Validate = require 'fhir_validate'
--    local V = Validate.new{ BaseUrl = 'https://hapi.fhir.org/baseR4' }
--
--    local Status, Outcome, Reason = V:check(FhirJsonString)
--    -- Status is 'valid' | 'invalid' | 'unknown'
--
-- Meant to be called from an adapter *before* it sends. An Epic, Cerner or HAPI
-- adapter can validate a resource it built and refuse to POST an invalid one:
--
--    if Validate.new{ BaseUrl = Base }:check(PatientJson) ~= 'valid' then
--       linkiir.log.error('refusing to send a resource that did not validate')
--       return
--    end
--
-- Design rules, all deliberate:
--
--   * Remote only. No local validator, no bundled schema. $validate is a FHIR
--     operation; the server that will store the data is the one that decides
--     whether it is acceptable.
--   * Fail closed. Anything short of a conclusive "no errors" is not treated as
--     valid. A timeout, a 4xx/5xx, a malformed response, or a server that
--     cannot resolve the requested profile are all 'unknown', never 'valid'
--     and never 'invalid'.
--   * HTTP 200 can still be invalid. $validate answers 200 and puts the verdict
--     in an OperationOutcome, so the HTTP status is not the verdict.
--   * The submitted resource is never mutated. check() sends the bytes it was
--     given, so a caller that forwards on 'valid' forwards exactly what was
--     validated.
-- ---------------------------------------------------------------------------

local M = {}

-- Internal default; not a node setting. A catalog validator does not expose a
-- timeout knob - 15s is enough for a synchronous $validate and short enough to
-- fail closed rather than hang a workflow.
local DEFAULT_TIMEOUT = 15

-- FHIR issue codes that mean "the validator could not do the job", as opposed
-- to "the resource is wrong". A server reports these when the requested profile
-- is not installed or cannot be resolved. Matched on the code, not on English
-- diagnostic text, which varies by server and version.
local UNRESOLVABLE_CODES = {
   ['not-supported'] = true,
   ['not-found']     = true,
}

local Client = {}
Client.__index = Client

-- Classify a linkiir.link.web response into a verdict.
--   returns status ('valid'|'invalid'|'unknown'), outcome table or nil, reason
local function classify(Response)
   -- linkiir.link.web returns nil, err on transport failure.
   if not Response then
      return 'unknown', nil, 'no response from the validation server'
   end
   -- live = false: nothing was sent, so there is no verdict. Not a pass.
   if Response.simulated then
      return 'unknown', nil, 'Live Mode is off, no validation request was sent'
   end
   -- A non-200 means the operation did not conclude. Never INVALID - we did not
   -- get a verdict on the resource, we failed to ask.
   if type(Response.code) ~= 'number' or Response.code ~= 200 then
      return 'unknown', nil,
         'validation did not complete (HTTP ' .. tostring(Response.code) .. ')'
   end

   local Ok, Outcome = pcall(linkiir.json.parse, Response.body)
   if not Ok or type(Outcome) ~= 'table'
      or Outcome.resourceType ~= 'OperationOutcome'
      or type(Outcome.issue) ~= 'table' or #Outcome.issue == 0 then
      return 'unknown', nil, 'the server did not return a usable OperationOutcome'
   end

   local FatalOrError = false
   for _, Issue in ipairs(Outcome.issue) do
      local Severity = tostring(Issue.severity or '')
      local Code = tostring(Issue.code or '')
      if Severity == 'fatal' or Severity == 'error' then
         -- A profile the server cannot resolve is a question it could not
         -- answer, not a resource that failed. Fail closed as UNKNOWN so a
         -- missing profile is never silently downgraded to base-R4 validation.
         if UNRESOLVABLE_CODES[Code] then
            return 'unknown', Outcome,
               'the server could not resolve the requested profile'
         end
         FatalOrError = true
      end
   end

   return FatalOrError and 'invalid' or 'valid', Outcome, nil
end

-- Validate one FHIR resource.
--
--   FhirJson - the resource as a JSON string, sent unchanged
--   Opts     - optional { profile=, live= } overriding the client defaults
--
-- Returns status, outcome, reason. Status is always one of 'valid', 'invalid'
-- or 'unknown'; outcome is the parsed OperationOutcome when there is one; reason
-- explains an 'unknown' or is nil.
function Client:check(FhirJson, Opts)
   Opts = Opts or {}

   if type(FhirJson) ~= 'string' or FhirJson == '' then
      return 'unknown', nil, 'no FHIR resource to validate'   -- fail closed
   end

   local Ok, Resource = pcall(linkiir.json.parse, FhirJson)
   if not Ok or type(Resource) ~= 'table'
      or type(Resource.resourceType) ~= 'string' or Resource.resourceType == '' then
      return 'unknown', nil, 'input is not a FHIR resource (no resourceType)'
   end
   local ResourceType = Resource.resourceType

   if self.allowed and not self.allowed[ResourceType] then
      return 'unknown', nil, 'resource type not allowed for validation: ' .. ResourceType
   end

   if self.base_url == '' then
      return 'unknown', nil, 'no FHIR Base URL is configured'
   end

   -- Type-level validate: POST <base>/<ResourceType>/$validate. This does not
   -- create the resource - it is the read-shaped validate operation.
   local Url = self.base_url .. ResourceType .. '/$validate'

   local Params
   local Profile = Opts.profile or self.profile
   if Profile and Profile ~= '' then
      Params = { profile = Profile }
   end

   local Live = Opts.live
   if Live == nil then Live = self.live end
   if Live == nil then Live = true end

   local Response = linkiir.link.web.post{
      url       = Url,
      params    = Params,
      body      = FhirJson,     -- byte-for-byte; never re-serialised
      headers   = {
         ['Content-Type'] = 'application/fhir+json',
         ['Accept']       = 'application/fhir+json',
      },
      auth      = self.auth,
      timeout   = self.timeout,
      verifyTls = self.verify_tls,
      live      = Live,
   }

   return classify(Response)
end

-- The most output any one summary line will list, so a server that returns
-- dozens of issues does not produce an unreadable log line.
local MAX_SUMMARIZED = 5

-- Collapse an OperationOutcome's issues into one readable line, for logging a
-- verdict without dumping the whole resource. Never includes the submitted
-- resource, so it is safe to log.
--
-- Only the issues that matter to a verdict are listed: fatal, error, and
-- warning. FHIR servers (HAPI in particular) also emit 'information' issues
-- that are validator bookkeeping - line/column pointers, message ids, "Unknown
-- extension http://hl7.org/fhir/StructureDefinition/operationoutcome-issue-*" -
-- which are noise to an operator and never change whether a resource is valid.
-- Those are counted, not printed. A resource that passes with only that
-- bookkeeping therefore logs a clean "no blocking issues" rather than a wall of
-- "Unknown extension" lines.
function M.summarize(Outcome)
   if type(Outcome) ~= 'table' or type(Outcome.issue) ~= 'table' then
      return 'no issues reported'
   end

   local Notable, InfoCount = {}, 0
   for _, Issue in ipairs(Outcome.issue) do
      local Severity = tostring(Issue.severity or 'information')
      if Severity == 'fatal' or Severity == 'error' or Severity == 'warning' then
         local Text = (type(Issue.details) == 'table' and Issue.details.text)
            or Issue.diagnostics or Issue.code
         if Text then
            Notable[#Notable + 1] = Severity .. ': ' .. tostring(Text)
         end
      else
         InfoCount = InfoCount + 1
      end
   end

   if #Notable == 0 then
      if InfoCount > 0 then
         return 'no blocking issues (' .. InfoCount .. ' informational note'
            .. (InfoCount == 1 and '' or 's') .. ')'
      end
      return 'no issues'
   end

   local Shown = Notable
   local Suffix = ''
   if #Notable > MAX_SUMMARIZED then
      Shown = {}
      for i = 1, MAX_SUMMARIZED do Shown[i] = Notable[i] end
      Suffix = ' | (+' .. (#Notable - MAX_SUMMARIZED) .. ' more)'
   end
   return table.concat(Shown, ' | ') .. Suffix
end

-- Build a client.
--
--   BaseUrl      - FHIR base URL, e.g. https://hapi.fhir.org/baseR4
--   Profile      - default profile canonical to validate against; empty
--                  validates against the resource's base definition
--   Auth         - linkiir.link.web auth table, e.g. { type='bearer', token= }
--   AllowedTypes - list of resource types this client will validate; others
--                  return 'unknown' rather than being sent
--   Timeout      - seconds, default 20
--   VerifyTls    - verify the server certificate, default true
--   Live         - perform real requests, default true
function M.new(T)
   T = T or {}
   local BaseUrl = T.BaseUrl or ''
   if BaseUrl ~= '' and BaseUrl:sub(-1) ~= '/' then BaseUrl = BaseUrl .. '/' end

   local Allowed
   if type(T.AllowedTypes) == 'table' and #T.AllowedTypes > 0 then
      Allowed = {}
      for _, Type in ipairs(T.AllowedTypes) do Allowed[Type] = true end
   end

   return setmetatable({
      base_url   = BaseUrl,
      profile    = T.Profile or '',
      auth       = T.Auth,
      allowed    = Allowed,
      timeout    = tonumber(T.Timeout) or DEFAULT_TIMEOUT,
      verify_tls = T.VerifyTls ~= false,
      live       = T.Live ~= false,
   }, Client)
end

-- Build a client from the current node's own configuration fields.
--
-- The node exposes only two settings - FHIR Base URL and an optional Profile
-- Canonical. TLS verification is always on and the timeout is the internal
-- default; neither is a knob a catalog node should offer. The resource type is
-- taken from the resource itself (see check), so there is no Resource Type
-- setting and no allow-list by default - the same node validates Patient,
-- Observation, Encounter, and so on.
function M.fromNodeConfig()
   local Config = linkiir.config.node()
   local Instance = M.new{
      BaseUrl = Config['FHIR Server URL'] or Config['FHIR Base URL'],
      Profile = Config['FHIR Profile'] or Config['Profile Canonical'],
   }
   return Instance, Config
end

-- ---------------------------------------------------------------------------
-- Simple one-call entry for the FHIR Validator node.
--
--   Opts = { data = <FHIR JSON string>, baseUrl = <FHIR base URL>,
--            profile = <optional profile canonical> }
--
-- Returns a result table:
--   { valid = <boolean>, status = 'valid'|'invalid'|'unknown',
--     summary = <one-line issue summary, safe to log - no submitted PHI> }
--
-- valid is true ONLY on a conclusive pass (an OperationOutcome with no fatal
-- or error issues). Both 'invalid' and 'unknown' return valid=false, so the
-- caller stops on anything that is not a clean pass - a timeout, an HTTP
-- failure, a malformed response, or an unresolved profile all stop, never
-- forward. The summary is built from issue severity/code/details only and never
-- includes the submitted resource, so it is safe to surface in an error.
-- ---------------------------------------------------------------------------
function M.validate(Opts)
   Opts = Opts or {}
   local Client = M.new{ BaseUrl = Opts.baseUrl, Profile = Opts.profile }
   local Status, Outcome, Reason = Client:check(Opts.data, { profile = Opts.profile })

   local Summary
   if Status == 'valid' then
      Summary = M.summarize(Outcome)
   elseif Status == 'invalid' then
      Summary = M.summarize(Outcome)
   else
      Summary = Reason or 'no validation verdict was obtained'
   end

   return { valid = (Status == 'valid'), status = Status, summary = Summary }
end

M.Client = Client
return M
