# cis_libs

A standalone FiveM library. It depends on no other library.

It is the shared boundary of the Cisoko platform and nothing more: it owns no
table, reads no config file, and reaches no framework. Detection aside, it
names no framework in its own code — the normalised framework surface lives in
`cis_core` and the third-party adapters live in `cis_bridge`.

## Attribution

**This notice must be retained in every copy and every distribution of this
software, in source or binary form, and in any substantial portion of it.**

- **Author:** Cisoko (SpecialStos)
- **Resource name:** `cis_libs`
- **Project:** https://github.com/SpecialStos/cis_libs
- **Documentation:** https://docs.cisoko.net

You may not remove or alter this notice, and you may not present this software
as your own work.

---

# Cisoko Community Source & Identity License
## Version 1.0 (2026-10-07)
## SPDX-License-Identifier: LicenseRef-Cisoko-CSIL-1.0

Copyright (c) 2024-2026 Cisoko (SpecialStos)

This is **not** the MIT License. The grant below is subject to the mandatory
conditions in Section 3. Those conditions are the point of this license.

### 1. Definitions

**Software** means this `cis_libs` source tree, its compiled or minified forms,
and any substantial portion of either.

**Canonical Name** means the exact FiveM resource name `cis_libs` (lowercase,
underscore, no prefix, no suffix).

**Licensor** means Cisoko / SpecialStos.

**You** means any person or legal entity exercising rights under this license.

### 2. Grant

Subject to the conditions in Section 3, Licensor grants You a worldwide,
royalty-free, non-exclusive license to:

- use, copy, modify, merge, publish, and distribute the Software
- run the Software on commercial FiveM / RedM / CFX servers
- integrate the Software with paid consumer resources, membership servers, and
  other monetized communities
- charge for your own original work that *depends on* the Software

This grant is **not** a trademark license, except the limited right to use the
Canonical Name as required by Section 3.1. This grant is **not** a right to
sublicense the Software under different terms. Anyone who receives a copy from
You receives it under this same license, from Licensor, not from You.

A defensive patent license is included for patent claims Licensor can license
that are necessarily infringed by the unmodified Software as distributed by
Licensor. That patent license ends if You file a claim alleging that the
Software infringes a patent.

### 3. Mandatory conditions

If You do not meet every condition in this section, the grant in Section 2
does not apply.

#### 3.1 Resource identity (no rebranding)

In any FiveM, RedM, or CFX runtime, server configuration, dependency manifest
(`fxmanifest.lua` / `__resource.lua`), export table, `@resource/` include, or
resource directory, this Software **must** remain named exactly:

    cis_libs

You may **not**:

- rename the resource folder
- start, ensure, or depend on this Software under another resource name
- declare `provide` so a differently named folder satisfies `dependency 'cis_libs'`
- copy the core primitives into a renamed or monolithic package that replaces
  `cis_libs`
- alias, wrap, or re-export the Software so consumers are told to depend on a
  name other than `cis_libs` (for example `mycity_lib`, `custom_libs`, or a
  framework core that swallowed this tree)

The name FXServer reports from `GetCurrentResourceName()` for this Software
must be `cis_libs`. That native returns the resource folder name.

#### 3.2 Attribution and non-appropriation (no claiming / no theft)

The copyright notice, this permission notice, and the original author credits
must be included in all copies or substantial portions of the Software.

You may **not** claim authorship of the Software or of base code derived
directly from it, even if You have introduced modifications or additions.

#### 3.3 Modifications

You may modify, tune, extend, and adapt the internal code for your server or
resources. Modified versions:

(a) must still comply with Section 3.1 (they must run as `cis_libs`);
(b) must clearly state in file headers or `CHANGELOG.md` that the original
    code was modified;
(c) must retain this license, unmodified in its legal terms;
(d) must not remove, disable, bypass, or invert the runtime identity check
    that refuses a folder name other than `cis_libs`.

#### 3.4 Distribution

You may distribute original or modified copies only under this license, still
named `cis_libs`, with this `LICENSE.md` intact.

You may **not** sell, escrow, or relicense the Software as a competing library
under another name. Selling a server, a membership, or an original resource
that *depends on* `cis_libs` is commercial use under Section 2 and is allowed.

#### 3.5 Commercial use

Commercial servers, paid scripts, and monetized communities are permitted to
use, run, and integrate with this Software, provided Sections 3.1 through 3.4
are strictly respected.

### 4. Termination

The rights granted in Section 2 end automatically if You breach this license.

They reinstate if You cure the breach in full within 30 days of receiving
notice, unless Licensor notifies You that reinstatement is refused because the
breach was willful rebranding, authorship theft, or a repeat violation.

On termination You must stop using and distributing the Software. Sections 5
and 6 survive termination.

### 5. Disclaimer of warranty

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.

### 6. Limitation of liability

IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
OR OTHER DEALINGS IN THE SOFTWARE.

---

## Community

- Documentation: <https://docs.cisoko.net>
- Discord: <https://discord.gg/cisoko>
- Issue tracker: <https://github.com/SpecialStos/cis_libs/issues>

## Third-party dependencies

`cis_libs` has **no runtime dependencies**. It does not require, vendor or
ship another FiveM library. Other resources remain under their own licences.
