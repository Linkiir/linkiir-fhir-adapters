-- ---------------------------------------------------------------------------
-- athena_health_token - access token cache
--
-- Athena access tokens are valid for about an hour. A Source Custom node keeps
-- one long-lived Lua worker and re-enters main() on each interval, so a
-- module-level table persists between polls.
--
-- Tokens are held in memory only. They never reach disk, which keeps a live
-- credential out of the project tree and out of git. The cost is one extra
-- token request per node restart.
-- ---------------------------------------------------------------------------

local M = {}

-- Keyed by "<client_id>@<base_url>" so a node configured against more than one
-- Athena environment cannot hand the wrong token to the wrong endpoint.
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
