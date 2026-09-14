# Stage 2 validation record — real vouchers + initial session auth (LOCAL ONLY)

> Status: **implemented + locally tested. NOT deployed to the EAP.**
> Full build log: `../STAGE2_BUILD.md`. Test evidence: `08-stage1-checks.md`
> (Stage 1) + results below. Stage 3 stays design-only (`09-…`).

## 1. Scope (locked)

IN: voucher allowlist/normalize, backend claim, `exitlevel` allow/deny,
`session_length = ceil(remaining/60)` + 10 Mbps rates from API, fail-closed
everywhere, single-session rebind (evict-old/allow-new, best-effort EAP deauth).
OUT: pause/resume accrual, custom status UI, `statuspath` switch, port-80/LuCI,
production seeding, EAP deployment.

## 2. Files (see repo root `../`)

* `../custombinauth.voucher.sh` — EAP claimant, deploys as
  `/usr/lib/opennds/custombinauth.sh` (stub backed up first). Acts ONLY on
  `action=auth_client` (`opennds/binauth_log.sh:287-298`); deauth callbacks pass
  through untouched. Decodes `custom` via `ndsctl b64decode` (sole permitted
  verb), extracts `voucher=`, uppercases, enforces `^[A-Z0-9-]{4,20}$`
  (entity-smuggling can never match ⇒ deny), claims via router-egress POST,
  parses `ALLOW secs up down [EVICT mac]` / `DENY reason`. No `eval`/backticks/
  direct-`ndsctl`/unquoted client data. Masked syslog only (no value, no PSK).
* `../backend/api.py` — stdlib HTTP/application layer + `psycopg` v3 for
  PostgreSQL production mode. `claim_voucher()` is the ONE validation
  function (fresh/rebind/idempotent/expiry/disable/paused paths + `events`
  audit). `POST /claim` (PSK body field, `compare_digest`) + `GET /session`
  JSON (the six Stage 3 questions) + `/healthz`. SQLite locally, PostgreSQL
  in production; `UP_KBPS`/`DOWN_KBPS` default 10240 (EAP calibration confirms
  the 10 Mbps mapping at deploy).
* `../backend/schema.sql` — production DDL (`vouchers` + `events`; `used_secs`,
  `resume_ts`, `PAUSED` present, never accrued in Stage 2).
* `../backend/seed.sql` — LOCAL TEST rows only (`TEST-6H`, `TEST-USED`,
  `TEST-DISABLED`, `TEST-PAUSED`). **`PORTAL-TEST` is retired**: absent ⇒
  `DENY unknown`. Production seeding is a separate manual step, no secrets here.
* `../backend/test_api.py`, `../tests/custombinauth_test.sh` — below.
* `../theme_voucher.sh` — markers only since Stage 1 (bypass → validation
  wording, `PORTAL-TEST` retired note). Forms, flow, CSS byte-identical behavior.

## 3. Decisions (override only with reason)

Strict uppercase `A-Z0-9-` (hyphens significant) · evict-old/allow-new
(private-MAC friendly) · fail-closed on deny/timeout/malformed/unconfigured
· `PORTAL-TEST` retired, `TEST-*` for local/manual tests · `PAUSED` denies on
the claim path (resume is Stage 3) · PSK env/file-only, EAP sole API caller.

## 4. Contract (EAP ↔ backend; browser never calls backend ⇒ CPD ≡ Chrome)

Request: `voucher, mac, ip, token, psk` (constrained charsets, no encoding layer).
Response line: `ALLOW <remaining_secs> <up> <down>[ EVICT <oldmac>]` or
`DENY <reason>` (generic codes; user page stays `REQUEST FAILED` for all denies).
`/session?code=` JSON: `exists/active/paused/remaining_seconds/active_session/meta`.

## 5. Results (local, reproducible)

* `sh -n` ×3 + `ast.parse` ×2 clean (`shellcheck` absent, noted).
* `test_api.py`: 9/9 OK (fresh 21600, unknown/invalid/disabled/expired/paused
  deny, expiry marking, rebound+EVICT, idempotent re-request, session_info).
* `custombinauth_test.sh`: 11/11 PASS (allow 360 min, denies, zero-fetch
  pre-network rejects, backend-down closed, bad-reply closed, ceil 21601→361,
  deauth passthrough, lowercase normalize, evict hook `daemon_deauth OLD`,
  unconfigured-URL closed).
* Live HTTP round-trip (temp DB + real server): allow line, retired-code deny,
  charset deny, `/session` JSON correct.
* Audits: no `eval`/backticks/direct-`ndsctl` in code; no `PORTAL-TEST` logic;
  secrets scan clean; `opennds/*` mtimes unchanged; theme re-render leak-free.

## 6. Still manual (NOT done here)

EAP→API reachability, 10 Mbps rate calibration, CPD + Chrome walks with a `TEST`
voucher, retired-code deny confirmation, production seed + PSK install, deploy
itself (`../STAGE2_BUILD.md` §6–§7, unexecuted). Rollback = restore stub (+
revert any UCI options if added).
