Security = {}
Security.EventPrefix = "cis_libs"
Security.Debug = false

-- Resources allowed to mutate doors and sync entities. Empty means "nobody",
-- on a fresh install: a brand new server has no authorised callers yet, and
-- defaulting to allow-all only helps during setup while leaving the exposure
-- behind afterwards.
--
-- An empty list is a SETUP CONVENIENCE, NOT A PRODUCTION POSTURE. Any other
-- server-side resource can then add doors, break them, and rewrite sync
-- records for every player. On a live server, name every resource that does.
--
-- Adding an entry is a one-line, no-restart-of-your-other-resources change:
--
--   Security.AuthorizedResources = {
--       "cis_storeRobberies",
--       "cis_housing",
--   }
--
-- An install that already ran cis_libs before this default existed keeps the
-- old permissive behaviour; see COMPATIBILITY.md section 6.
Security.AuthorizedResources = {
    -- "my_resource",
}

-- Either a boolean, or a function(src, reason) for a custom kick.
Security.DropPlayer = true
function cisAnticheatDropPlayer(src, reason)
    DropPlayer(src, "cis_libs: Kicked. If you believe this is a mistake, please contact the server owner.")
end

-- Hand the custom handler above to the library. Without this, the boolean
-- branch is used and the function is never called.
Security.DropPlayer = cisAnticheatDropPlayer
