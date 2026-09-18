-- ---------------------------------------------------------------------------
-- FHIR Validator - Transform Custom
--
-- Receives a FHIR resource as JSON, validates it against a FHIR server's
-- $validate operation, and forwards the resource downstream unchanged only when
-- it validates. Anything short of a conclusive pass is not forwarded: the node
-- fails closed.
--
-- Put it between a resource producer (FHIR Resource Creator, an HL7-to-FHIR
-- mapping) and a FHIR destination (Epic, HAPI, OmniVera). It stops an invalid
-- resource reaching the server.
--
-- What to change where:
--   which server validates, the profile, the routing  ->  node config
--   how $validate is called and the verdict decided    ->  fhir_validate library
-- ---------------------------------------------------------------------------
package.path = linkiir.sys.nodeDir() .. '/fhir_validate/?.lua;' .. package.path
local Validate = require 'fhir_validate'

-- Route a rejected resource. With an Error Topic configured the original bytes
-- go there so a downstream handler can quarantine or alert; otherwise the
-- resource simply stops here.
local function route(Data, Action, Topic, Status)
   if Action == 'Push to error route' and Topic and Topic ~= '' then
      linkiir.flow.push{ data = Data, topic = Topic,
                         metadata = { fhir_validation = Status } }
      return true
   end
   return false
end

function main(Data)
   local Fhir, Config = Validate.fromNodeConfig()

   local Status, Outcome, Reason = Fhir:check(Data)

   if Status == 'valid' then
      -- Valid by FHIR includes "valid with warnings". Block those only when the
      -- operator has asked to.
      if Config['Block Warnings'] and Outcome then
         for _, Issue in ipairs(Outcome.issue or {}) do
            if tostring(Issue.severity) == 'warning' then
               linkiir.log.warn('FHIR Validator: valid but warnings present and '
                  .. 'Block Warnings is on - not forwarding. '
                  .. Validate.summarize(Outcome))
               route(Data, Config['On Invalid'], Config['Error Topic'], 'warning-blocked')
               return
            end
         end
      end
      -- Forward the exact bytes that were validated.
      linkiir.flow.push{ data = Data, metadata = { fhir_validation = 'valid' } }
      linkiir.log.info('FHIR Validator: valid, forwarded.')
      return
   end

   if Status == 'invalid' then
      linkiir.log.error('FHIR Validator: invalid - ' .. Validate.summarize(Outcome))
      route(Data, Config['On Invalid'], Config['Error Topic'], 'invalid')
      return
   end

   -- unknown: no verdict was obtained. Fail closed.
   linkiir.log.warn('FHIR Validator: unknown - ' .. tostring(Reason)
      .. ' (failing closed, not forwarding)')
   route(Data, Config['On Unknown'], Config['Error Topic'], 'unknown')
end

-- ---------------------------------------------------------------------------
-- Using the library directly (the more common use)
--
-- The verdict logic is the fhir_validate library, so another node - or an
-- adapter about to send - can validate before it acts, without this node in
-- the workflow:
--
--    package.path = linkiir.sys.nodeDir() .. '/fhir_validate/?.lua;' .. package.path
--    local Validate = require 'fhir_validate'
--    local V = Validate.new{ BaseUrl = 'https://hapi.fhir.org/baseR4' }
--
--    local Status = V:check(PatientJson)
--    if Status ~= 'valid' then
--       linkiir.log.error('refusing to send a resource that did not validate')
--       return
--    end
--    -- only now hand PatientJson to the FHIR adapter that will create it
-- ---------------------------------------------------------------------------
