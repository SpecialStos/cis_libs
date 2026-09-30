-- =============================================================================
--  cis_libs -- security configuration  (SERVER SIDE ONLY)
--
--  Everything in this file is a SECURITY decision. The defaults below were
--  chosen so that a fresh clone is closed by default, and so that a stranger
--  who drops this on a live server without reading a word is not exposed.
--
--  Of the three keys here, one matters more than the other two combined:
--
--      Security.AuthorizedResources
--
--  Read the block under it before you run this on anything real.
--
--  Nothing in this file is a secret, and none of it reaches the client: the
--  authorised-resource list and the kick handler are stripped from the payload
--  the server sends out, so a player can never read either back.
-- =============================================================================

Security = {}

-- ------------------------------------------------------------------ IDENTITY
-- The prefix on every net event the library uses, on both sides:
--     "<prefix>:doorlock:addDoor", "<prefix>:doorlock:requestState", ...
--
-- SAFE DEFAULT: "cis_libs". Keep it. It is the name this library publishes its
-- events under, and the compiled-in fallback in client/ and server/ is the same
-- string.
-- IF YOU CHANGE IT: every event name changes with it. Any companion resource
-- that triggers these events directly must be changed to match in the same
-- edit, or it will silently stop working -- the trigger is not refused, it
-- simply never arrives. Only change it if two cis_libs-derived resources must
-- coexist on one server and their event sets would otherwise collide.
Security.EventPrefix = "cis_libs"

-- RESERVED. Nothing in this resource reads it; `Config.Printing.Debug` is the
-- flag that is actually wired up. It is kept so an existing config keeps
-- loading, but DO NOT BUILD ANYTHING ON IT: setting it true will not turn
-- anything on. For diagnostics, use Config.Printing.Debug in master_config.lua.
Security.Debug = false

-- =============================================================================
--  SECURITY.AuthorizedResources  --  READ THIS
--
--  THE SHIPPED DEFAULT IS AN EMPTY LIST, AND ON A FRESH INSTALL AN EMPTY LIST
--  MEANS "NOBODY". No resource other than cis_libs itself may add a door,
--  break a door, or write a sync record. Every attempt from another resource
--  is refused.
--
--  This is the intended default and it is not a bug. A new server has no
--  authorised callers yet, so the honest answer to "who may mutate doors?"
--  is nobody. Defaulting to allow-all instead would help nobody during setup and
--  would leave the exposure in place afterwards, which is the part that matters
--  at 3am.
--
--  WHAT "NOBODY" COSTS YOU: if you have a housing, robbery or garage resource
--  that calls the doorlock exports, those calls start returning false and that
--  resource stops working. That is a five-line fix, listed below -- it is not a
--  reason to run allow-all.
--
--  ONE EXCEPTION, FOR EXISTING INSTALLS ONLY: if this resource has ALREADY run
--  on this server -- detected by a config file cis_libs previously wrote, or by
--  a cis_doors table that already has rows -- the empty list keeps the older,
--  permissive behaviour instead, so an upgrade does not break a working server
--  overnight. You can check which way you fell with the cis_debug command in
--  the server console; it prints the posture on every boot either way. Full
--  detail in COMPATIBILITY.md section 6.
--
--  TO AUTHORISE YOUR OWN RESOURCES, add one string per resource name:
--
--      Security.AuthorizedResources = {
--          "cis_storeRobberies",
--          "cis_housing",
--      }
--
--  This needs no restart of the resources being listed -- only of cis_libs.
--  A resource can ask before it acts, rather than guessing:
--      if exports["cis_libs"]:InvokingAllowed() then ... end
--  and that call returns false rather than refusing mid-action, so you can warn
--  the player properly.
-- =============================================================================
Security.AuthorizedResources = {
    -- "my_resource",
}

-- ------------------------------------------------------------------- KICKING
-- What happens when the library decides a player is cheating: either a boolean
-- or a function(src, reason) for a kick of your own design.
--
-- SAFE DEFAULT: the handler below, which kicks with a generic message.
--
-- A note on the message: it is deliberately generic, and it deliberately tells
-- the player to contact the server owner. Naming the check that fired tells a
-- person exactly which guard to look for, and guards are the first thing
-- somebody wants to find. If you customise it, keep it that way.
--
-- Setting this to false is a legitimate choice -- ban on your own terms
-- elsewhere, or log-only while you investigate -- but be deliberate: with
-- false, nothing stops the player at all, only the log entry survives.
--
-- `src` is the player's server id, and `reason` is a short internal string.
-- Whatever you return is ignored; the library records the kick as having
-- happened either way.
Security.DropPlayer = true
function cisAnticheatDropPlayer(src, reason)
    DropPlayer(src, "cis_libs: Kicked. If you believe this is a mistake, please contact the server owner.")
end

-- Hand the custom handler above to the library. Without this line the boolean
-- from above is what the library sees, and the function is never called.
Security.DropPlayer = cisAnticheatDropPlayer