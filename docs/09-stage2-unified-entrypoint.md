# Stage 3 Unified `status.client` Entry Point — design record (NOT implemented)

> Status: **APPROVED AS A DESIGN TARGET (ChatGPT verdict). NOT approved for
> implementation yet. Stage 3 is NOT built.**
> Stage 2 scope lock: **REAL VOUCHER VALIDATION + INITIAL SESSION AUTHORIZATION only.**
> No pause/resume, no final status page, no port-80 change, no LuCI/firewall/DHCP change.
> Send this file to ChatGPT to check the plan before approving anything.

## 0. Fixed deployment facts (do not change in Stage 2)

* `gatewayfqdn=status.client`, `gatewayport=2050`, `statuspath=/usr/lib/opennds/client_params.sh`
* Port 80 belongs to LuCI. No proxy or web framework on the EAP.
  Untouched until a later, separately tested decision (see §4b).
* `theme_voucher.sh` (Stage 1) proven inside Android CPD — frozen path.
* One voucher backend, one validation logic for all browsers (never per-browser DB/logic).
* OpenNDS identifies `gatewayfqdn` as the simulated client-status hostname and
  `statuspath` as the script generating that status page, and warns that
  `gatewayfqdn` behavior can affect port-80 services — hence §4b traces the real
  request path before any Stage 3 build.

## 1. Current Chrome flow (observed)

```text
Chrome → http://status.client/ → Session Status → Continue
→ http://status.client/login? → OpenNDS /opennds_preauth/
→ WI-FI E-VOUCHER → voucher → CONNECT → VOUCHER RECEIVED
→ Continue → authentication → Session Status
```

Works, but exposes stock intermediate pages (`Session Status`, `Continue`,
`To login, click or tap Continue`) that must disappear in production.

## 2. Current Android CPD flow (observed, already good)

```text
Wi-Fi connect → CPD detect → status.client → WI-FI E-VOUCHER
→ voucher → CONNECT → auth (CPD may close immediately after)
```

CPD-safe today: inline CSS, ordinary GET forms, no JS/CDN/fonts/`href`-critical
navigation. This path must keep working unchanged.

## 3. Desired unified flow (Stage 3 target)

```text
http://status.client/ → custom entry/status handler
├── unauthenticated → render WI-FI E-VOUCHER directly → customer submits
│       → legitimate /opennds_preauth/ request → theme_voucher.sh → BinAuth
├── authenticated   → custom status: CONNECTED + remaining + voucher + PAUSE
└── paused          → custom status: PAUSED + remaining + Internet OFF + RESUME
```

CORRECTION #1 (binding): the customer-visible intermediate pages disappear,
but the legitimate `/opennds_preauth/` request still occurs as part of
authentication. The status handler must NOT execute PreAuth internally,
simulate it, or short-circuit it — it renders the login form whose submit
target is the real FAS endpoint. No bypass of the OpenNDS authentication
protocol.

Single customer entry point. OpenNDS machinery stays underneath; only the
customer-visible layer becomes unified. Browser type changes presentation
lifecycle only — never auth logic or backend.

## 4. Which component produces the intermediate pages today

`statuspath` handler `/usr/lib/opennds/client_params.sh`, invoked by MHD as:

```sh
client_params.sh $status $clientip $b64query   # client_params.sh:5-7
```

For `status`/`err511` it runs `header; body; footer` (`client_params.sh:348-350`).
The visible intermediates come from `body()`:

* status branch: account block + `Logout → $url/opennds_deny/` + Refresh
  (`client_params.sh:202-271`, Logout form at `217`).
* err511 branch: `To login, click or tap Continue → $url/login`
  (`client_params.sh:273-280`).

`gatewayfqdn` only selects the display URL (`320-324`). The ThemeSpec
(`theme_voucher.sh`) is NOT the source of these pages.

## 4b. Routing investigation (required BEFORE any Stage 3 build)

CORRECTION #4 (binding): do NOT assume replacing `statuspath` gives ownership
of TCP port 80. Trace and document the exact path first, with zero config changes:

```text
http://status.client/ → DNS/resolution → port/interception behavior
→ OpenNDS MHD/status handling → statuspath handler
```

Checklist (read-only EAP + client observation):

* How does `status.client` resolve for unauthenticated vs authenticated clients
  (DNS hijack vs host entry, and what answers port 80 vs 2050)?
* Which MHD route serves `statuspath` and which serves `/opennds_preauth/`?
* What do unauthenticated / authenticated / deauthenticated clients each receive
  for `http://status.client/` today (headers + body)?
* Confirm LuCI on port 80 is unaffected in every state.

Do NOT move LuCI. Do NOT take over port 80. Do NOT add nginx/reverse proxy.
Do NOT add a web framework to the EAP. Safest-first remains a
statuspath replacement/extension with existing routing preserved — but only
after the trace above is documented and ChatGPT-approved.

## 5. What must eventually be replaced/extended (Stage 3 only)

Fork/replace **only** the status handler (proposed `client_params_voucher.sh`,
`statuspath` switch in Stage 3 — explicitly NOT in Stage 2). Requirements:

* Keep the MHD calling convention (`$1/$2/$3`) and keep serving `err511`.
* Branch internally: unauthenticated → render the voucher login form whose
  submit target is the **real** `/opennds_preauth/` FAS flow (reuse
  `theme_voucher.sh` behavior); the handler itself never executes PreAuth —
  the customer's browser still makes the legitimate PreAuth request
  (Correction #1). Authenticated/paused → render custom status from backend state.
* Never reimplement auth, firewall, or BinAuth. No proxy/framework on the EAP.
  No port-80 takeover, no LuCI move (see §4b).
* `libopennds.sh`, `binauth_log.sh`, `theme_voucher.sh` stay untouched.

## 6. Authenticated vs unauthenticated (server-side only)

Authoritative signal: `ndsctl json $clientip` in `parse_parameters()`
(`client_params.sh:96-119`). The allowlist already includes
`state, session_start, session_end, token` (`103-106`) plus usage/rate fields.

CORRECTION #2 — paused identity (binding): `ndsctl deauth` removes the
OpenNDS client record (`ndsctl json <client>` → `{}`). Therefore:

* Persistent voucher/session state lives in PostgreSQL, never in OpenNDS alone.
* Never use IP, MAC, token, or client-supplied URL parameters as permanent
  identity or authorization. MAC is a transient selector/metadata only.
* Private/randomized MAC must never brick a voucher. Secure fallback:
  no active OpenNDS record + no securely resumable browser/session identity
  → render WI-FI E-VOUCHER login → customer re-enters voucher → backend
  reports PAUSED → show RESUME. Never auto-map a new randomized MAC to an old
  paused session.

CORRECTION #3 — CONNECTED rule (binding): the handler must NOT decide
CONNECTED from `state = Authenticated` alone. Required conjunction:

```text
live OpenNDS Authenticated AND backend ACTIVE AND session association valid
= CONNECTED
```

If the backend says expired/paused/disabled, the status layer must NOT claim
CONNECTED even when a stale OpenNDS record still exists. Backend authoritative.

Stage 3 rule:

* Live OpenNDS authenticated AND `session_end` in the future AND backend ACTIVE
  with valid association → authenticated → custom status.
* No record / `Preauthenticated` / expired `session_end` / backend
  expired-disabled → unauthenticated → login.
* Deauthenticated at OpenNDS level + backend `paused` flag with
  `remaining > 0` → paused → RESUME (re-identified via voucher re-entry;
  Stage 2 schema carries the columns only).

Caveats recorded for the implementer: `null → Unlimited` (`110-112`),
missing → `Unavailable` (`114-118`), `date -d @...` guards (`130-138`), and the
stock parser omits `custom` — the Stage 3 fork must add `custom` (b64decode →
voucher identity) next to `state`.

## 7. Preserving OpenNDS security

* Allow/deny stays with openNDS + BinAuth exit code (`binauth_log.sh:300-309`
  contract). The entry handler is **render-only**: no `ndsctl auth`, no
  nftables writes, no grant capability on any unauthenticated endpoint.
* Sole path to Internet remains
  `landing_page → auth_log → ndsctl auth → BinAuth auth_client`
  (existing `theme_voucher.sh` flow).
* `check_authenticated()` (`libopennds.sh:578-597`) stays informational; never
  an auth decision. Rollback = single `statuspath` revert to stock.

## 8. Android CPD compatibility (Stage 3 must keep)

* Same CPD-safe constraints as Stage 1 (`libopennds.sh:2306-2313` warnings):
  inline CSS, GET forms, no JS/CDN/fonts/`href`-critical steps.
* Unauthenticated CPD lands directly on the voucher form with zero extra taps
  (`Session Status → Continue → Login` must never be customer-visible).
* Auth completes on the existing thankyou → Continue → landing tap; immediate
  CPD close after auth is expected success, never treated as failure
  (landing page already informational-only).
* No CPD-specific branches, UA sniffing, separate backends, or separate templates.

## 9. Chrome compatibility (same system, no fork)

* Same handler, states, backend: `http://status.client/` shows voucher login
  when unauthenticated (no stock detour) and custom status when
  authenticated/paused.
* The `status.client/login? → preauth` hop remains a real PreAuth request
  (Correction #1) but is never a visible technical page — the login form posts
  straight into it. Back/refresh safe (idempotent GET renders;
  the single claim happens once in BinAuth behind backend idempotency).
* One backend, one validation function, one voucher table for CPD and Chrome;
  only browser lifecycle behavior may differ.

## 10. Status integration with voucher session state (interface Stage 2 leaves behind)

Stage 2 backend (Ubuntu + PostgreSQL, single validation function, single DB for
both browsers) must be able to answer — implemented in Stage 2 as
`backend/api.py` (`POST /claim` line protocol for the EAP claimant,
`GET /session` JSON for these six questions; EAP uses `/claim` only):

* `voucher/session exists?`, `authenticated?`, `paused?`,
  `remaining_seconds?`, `active client/session?`, `client metadata?`
* EAP is the API caller (WAN egress); the client browser never calls the
  backend, so CPD and Chrome get identical answers with zero walled-garden
  exceptions and no client-type input (UA logged as metadata only).
* Join key stays `custom` (b64 `voucher=...`): `ndsctl json` custom ↔ backend
  code. MAC remains a transient selector/metadata, never permanent identity and
  never trusted from URL params.
* Stage 2 ends at validation + initial authorization
  (`session_length = ceil(remaining/60)`, 10 Mbps rates, `exitlevel` allow/deny).
  `used/resume_ts/paused` columns exist for Stage 3 but do not accrue yet.

## Guardrails (binding on Stage 2 and Stage 3)

* Never trust client-supplied voucher/MAC/URL params at the entry layer;
  backend authoritative; generic fail pages (no invalid-vs-expired oracle,
  no raw backend/DB errors to customers);
  voucher/custom never in visible text (Stage 1 privacy rule carries over).
* Entry/status handler is render-only: no `ndsctl auth`, no firewall changes,
  no direct Internet grants, no URL-param/MAC-as-proof authorization. Sole
  grant path stays ThemeSpec → `auth_log()` → `ndsctl auth` → `binauth_log.sh`
  → `custombinauth.sh` → backend decision → OpenNDS.
* Stage 2 exit: validation + initial auth. Out: pause/resume, final status UI,
  port-80/LuCI/firewall/DHCP changes, per-browser logic or databases.
* Port 80 / LuCI untouched until a later, separately tested decision (see §4b).

## Review checklist for ChatGPT

* [ ] Intermediates correctly attributed to `client_params.sh:202-280`, not the ThemeSpec?
* [ ] Fork-only-status-handler avoids touching `libopennds.sh`/`binauth_log.sh`/firewall/ports?
* [ ] Correction #1: visible intermediates gone but real PreAuth request preserved (no bypass)?
* [ ] Correction #2: paused re-identification via voucher re-entry; no MAC/IP/token/URL identity?
* [ ] Correction #3: CONNECTED requires OpenNDS + backend ACTIVE + valid association (backend wins)?
* [ ] Correction #4: routing trace (§4b) documented before build; port 80/LuCI untouched?
* [ ] Correction #5: CPD + Chrome share one flow, one DB, one validation function; CPD-close = success?
* [ ] Auth-state rule uses `ndsctl json state/session_end` (+`custom` added), never URL params?
* [ ] No grant path outside BinAuth; entry layer render-only with clean rollback?
* [ ] Backend interface covers all six Stage 3 questions?
* [ ] No Stage 3 implementation, no Stage 2 destabilization?
