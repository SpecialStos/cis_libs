# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.1.x | yes |
| older builds | no: upgrade to the latest 1.1.x release |

## Reporting a vulnerability

Report it privately through GitHub: on this repository, open the
**Security** tab and choose **Report a vulnerability**. Do not open a public
issue, pull request or Discord post for it.

Please include:

- the cis_libs version (`version` in `fxmanifest.lua`) and the server build;
- which side runs the attack (a client, another server resource, the NUI
  page) and what it reaches;
- the smallest steps or script that reproduce it.

We aim to answer within 7 days and to say then whether we accept the report
and when a fix is expected. A fix ships as a patch release with a line under
**Security** in `CHANGELOG.md`. We credit the reporter there unless they ask
us not to.

## What counts

In scope: anything that lets a client, or a server resource that does not own
a record, do what `DOCUMENTATION.md` says cis_libs refuses. For example: a
mutating export accepted from a resource that is not authorised, a net event
or callback payload that gets past its size or schema limits, another
resource's zones, callbacks, commands or capability slots changed or
released, or the NUI page driven by another page.

Out of scope: a server whose owner turned the protections off
(`cis_allow_any_resource`, `AllowAnyResource`, or a resource added to the
authorised list), and bugs in a framework, inventory or other third-party
resource that cis_libs does not ship.
