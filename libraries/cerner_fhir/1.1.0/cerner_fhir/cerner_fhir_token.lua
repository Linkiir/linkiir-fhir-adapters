-- ---------------------------------------------------------------------------
-- cerner_fhir_token - access token cache
--
-- Cerner access tokens are valid for a limited time, so re-authenticating on
-- every request would be wasteful. A Source Custom node keeps one long-lived
-- Lua worker and re-enters main() on each interval, so a module-level table
-- persists between polls and is all the storage this needs.
--
-- Tokens are held in memory only. They never reach disk, which keeps a live
-- credential out of the project tree and out of git. The cost is that a node
-- restart discards the token and the next poll fetches a fresh one.
-- ---------------------------------------------------------------------------

local M = {}

-- Keyed by "<client id>@<base url>" so a node configured against more than one
-- Cerner environment cannot hand the wrong token to the wrong endpoint.
local Cache = {}

-- Treat a token as expired this many seconds early, so one cannot lapse
-- between the check and the request that uses it.
M.EXPIRY_SKEW = 60

-- Look up a token. Returns { token=, expires_at= }, or nil when there is no
-- entry or the entry is within EXPIRY_SKEW of expiring.
function M.get(Key)
   local Entry = Cache[Key]
   if not Entry then return nil end

   if Entry.expires_at - M.EXPIRY_SKEW <= os.time() then
      Cache[Key] = nil
      return nil
   end

   return Entry
end

-- Store a token against its absolute expiry time. Returns the stored entry.
function M.put(Key, Token, ExpiresAt)
   Cache[Key] = { token = Token, expires_at = ExpiresAt }
   return Cache[Key]
end

-- Drop one entry, or the whole cache when called with no key.
function M.clear(Key)
   if Key == nil then
      Cache = {}
   else
      Cache[Key] = nil
   end
end

return M
