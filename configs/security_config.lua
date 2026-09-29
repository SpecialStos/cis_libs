Security = {}
Security.EventPrefix = "cis_libs"
Security.Debug = false
-- Empty list = any server-side caller is allowed to mutate doors and sync.
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
