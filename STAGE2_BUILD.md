# Stage 2 Build — real voucher validation + initial session auth (LOCAL ONLY)

> Send to ChatGPT for review before ANY EAP deployment.
> Nothing was copied to the EAP. No `uci`/`ssh`/`scp` executed. No secrets committed.
> Stage 3 remains design-only (`docs/09-stage2-unified-entrypoint.md`, now corrected).

## 1. Files created

* `custombinauth.voucher.sh` — EAP claimant. Deploy target (MANUAL, later):
  `/usr/lib/opennds/custombinauth.sh` (backup stub first). Sourced by
  `opennds/binauth_log.sh:294-298`; overrides the six contract vars (280-309).
* `backend/schema.sql` — PostgreSQL DDL: `vouchers` + `events`, pause-ready
  columns (`used_secs`, `resume_ts`, `PAUSED`) present but Stage 2 never accrues.
* `backend/api.py` — API with stdlib HTTP/application layer + `psycopg` v3 for
  PostgreSQL production mode. ONE `claim_voucher()` function for CPD+Chrome.
  `POST /claim` → line protocol for busybox sh; `GET /session` → JSON answering
  the six Stage 3 questions; `GET /healthz`. SQLite explicit-dev, PostgreSQL prod.
* `backend/seed.sql` — LOCAL TEST rows only (`TEST-6H`/`TEST-USED`/`TEST-DISABLED`/
  `TEST-PAUSED`). `PORTAL-TEST` deliberately ABSENT (retired ⇒ DENY unknown).
* `backend/test_api.py` — 11 sqlite unittests (temp DB, no network).
* `tests/custombinauth_test.sh` — 33-case shell harness (stubbed ndsctl/fetch/hook).

## 2. Files modified (minimal, reviewed diffs)

* `theme_voucher.sh` — comments/userinfo markers ONLY (Stage 1 bypass → Stage 2
  validation wording; `PORTAL-TEST` retired note). Flow, forms, CSS untouched.
* `docs/09-stage2-unified-entrypoint.md` — the 6 required corrections:
  internal-PreAuth wording (§3/§5/§9), paused re-identification (§6),
  dual-state CONNECTED rule (§6), routing investigation §4b, CPD+Chrome
  one-backend (§8/§9), port-80/LuCI untouched (§0/§4b/§5/guardrails + checklist).
* Untouched: `opennds/*`, `index.*`, `status.html`, UCI, ports, firewall, DHCP,
  statuspath, status UI, pause/resume.

## 3. Decisions/defaults (flag if ChatGPT objects)

* Format: strict uppercase `A-Z0-9-`, 4–20 chars, hyphens significant.
  Entity-smuggled input (`&#59;` etc.) can never match ⇒ DENY.
* Conflict: evict-old/allow-new (private-MAC friendly); old MAC best-effort
  `daemon_deauth` via the documented binauth-callable hook, never fatal.
* Outage/unconfigured/malformed: fail-CLOSED (`exitlevel=1`, generic fail page).
* `PORTAL-TEST`: retired (absent ⇒ `DENY unknown`); local tests use `TEST-*`.
* `session_length = ceil(remaining/60)` (openNDS minute granularity), cap 1440;
  rates from API (`UP_KBPS`/`DOWN_KBPS`, default 10240; EAP calibration confirms
  the 10 Mbps mapping at deploy); quotas 0.
* `PAUSED` rows DENY on the claim path in Stage 2 (resume is Stage 3).
* PSK via env/`VOUCHER_PSK_FILE` (0600) + optional UCI names; PSK in POST body
  (no URL/logs); `compare_digest` server-side; EAP is the sole API caller
  (browser never touches backend ⇒ CPD ≡ Chrome, zero walled-garden changes).

## 4. Data flow (unchanged wire, now enforced)

```text
form → /opennds_preauth/ → $voucher → binauth_custom → encode_custom → custom
→ auth_log → ndsctl auth → BinAuth auth_client $7
→ custombinauth.voucher.sh: b64decode → allowlist → POST /claim {voucher,mac,ip,token}
→ ALLOW secs up down [EVICT old] ⇒ session_length/rates, exitlevel=0
→ DENY/* ⇒ exitlevel=1, generic REQUEST FAILED (no oracle, no leaks)
```

## 5. Local test results (all green, evidence below)

* `sh -n` ×3 + `ast.parse` ×2 → clean (`shellcheck` absent, noted).
* `backend/test_api.py`: 9/9 OK — fresh allow 21600, unknown/invalid/disabled/
  expired/paused deny, expiry marking, rebound+EVICT, same-MAC idempotent,
  six-question `session_info`.
* `tests/custombinauth_test.sh`: 11/11 PASS — allow 360 min, unknown deny,
  bad-charset/entity deny with ZERO fetch calls, backend-down deny, bad-reply
  deny, ceil 21601→361, deauth passthrough, lowercase normalize, evict hook
  (`daemon_deauth OLD`, sess 300), no-URL fail-closed.
* Live HTTP integration (temp DB + real server): `ALLOW 21600 10240 10240`,
  retype-lower allow, retired `PORTAL-TEST` → `DENY unknown`, `A;B` → `DENY
  invalid`, `/session` JSON active/remaining correct.
* Audits: no `eval`/backticks/direct-`ndsctl` in code (comment mentions only);
  no `PORTAL-TEST` logic; no committed secrets (PSK env-only; scan clean).
* Theme regression: `fasvarlist` gains `voucher`; login posts to preauth;
  landing `REQUEST SENT`, zero voucher-plaintext hits.

## 6. Manual deploy (DO NOT RUN — ChatGPT approves first)

```sh
# backend (Ubuntu host): install schema, seed PRODUCTION vouchers manually,
# set VOUCHER_PSK (secret, never in repo), run api behind systemd, open LAN port to EAP only
# EAP:
scp custombinauth.voucher.sh root@10.0.0.1:/tmp/custombinauth.voucher.sh
ssh root@10.0.0.1 'cp /usr/lib/opennds/custombinauth.sh /tmp/custombinauth.stub.bak && cp /tmp/custombinauth.voucher.sh /usr/lib/opennds/custombinauth.sh && sh -n /usr/lib/opennds/custombinauth.sh'
# configure VOUCHER_API_URL + 0600 PSK file (or uci voucher_api_url/voucher_psk_file), then live tests:
#  - EAP→API reachability + rate calibration (10 Mbps mapping) BEFORE customer traffic
#  - Android CPD + Chrome walks with TEST voucher; retired PORTAL-TEST must deny
```

Rollback: restore `/tmp/custombinauth.stub.bak` → `/usr/lib/opennds/custombinauth.sh`
(+ `uci revert`/restore if options added); no other component changed.

## 7. Out of scope (not built)

Pause/resume accrual, custom status UI, `statuspath` switch, port-80/LuCI work,
production seeding, EAP deployment itself.

## 8. Ask ChatGPT

* [ ] Six corrections in `docs/09` faithful to the verdict?
* [ ] `auth_client`-only + fail-closed + render-only entry layer preserved?
* [ ] Single DB/function, no per-browser branches, MAC never identity?
* [ ] Line protocol + `/session` JSON acceptable contracts?
* [ ] Evict-old/allow-new + `PORTAL-TEST` retirement + PAUSED-deny defaults OK?
* [ ] Safe to proceed to manual deploy after rate calibration?

## 9. Corrections round (approved scope, all tests green)

ChatGPT-mandated hardening, implemented locally, EAP untouched:

* `backend/api.py` — real PostgreSQL via `DATABASE_URL` (`psycopg` v3) with
  explicit backend selection (pg-only when configured; sqlite explicit-dev via
  `VOUCHER_DB`; refuse startup if neither); `%s`-placeholder adapter
  (`SELECT … FOR UPDATE` on pg, `BEGIN IMMEDIATE` encapsulated for sqlite);
  DB-side timestamps; `HOST` env (default 127.0.0.1); per-request try/except →
  generic `DENY`, tracebacks server-log only.
* `backend/schema.sql` — added `total_secs >= 0`, `used_secs >= 0`,
  `used_secs <= total_secs`; contract header (explicit operator schema install;
  `api.py` never runs DDL, `test_pg.py` loads `schema.sql` verbatim).
* `custombinauth.voucher.sh` — strict MAC (`XX:…` or empty), strict IPv4
  (malformed ⇒ pre-network deny), token allowlist `A-Za-z0-9._:-` 1–128
  (empty/forbidden ⇒ deny), strict reply shape (4 fields or 6 with `EVICT`
  + strict MAC), numeric caps (remaining ≤ 9999999, rates ≤ 1000000).
* Tests added: `backend/test_pg.py` (6, live pg), `backend/test_server.py`
  (3, LAN-bind + HTTP auth/leak), `tests/stage1_guard.sh` + manifest
  (frozen files + scope + accrual + ndsctl-surface), 12 reply-shape and
  8 ip/token vectors in the shell harness with fetch-call assertions.

Results: `test_api` 11/11 · `test_pg` 6/6 (postgres:16-alpine disposable,
`psycopg` 3.3.5) · `test_server` 5/5 (LAN-bind, chunked-body regression,
malformed-framing deny) · shell 33/33 + theme render 31/31 ·
guard PASS. No-fallback proven (pg-configured + unreachable ⇒ BackendError,
no sqlite file). Injection vectors denied pre-network (0 fetch calls).
Stage 1 manifest: core files unchanged (theme hash refreshed for approved
UI/flow changes, recorded in `tests/stage1_manifest.sha256`).

## 10. Enforcement inversion + direct-to-status (production findings)

Live EAP forensics proved this daemon honors the quotas carried IN the
`ndsctl auth` request and may skip BinAuth on the FAS path (24 h ghost
grants, zero backend contact). Enforcement therefore moved to where it
cannot be skipped: `theme_voucher.sh` pre-validates via `voucher_api_claim()`
and calls the auth entry ONLY on ALLOW with explicit policy quotas
(deny/failure/empty ⇒ no call ⇒ no grant possible). Legacy landing hardened
identically (presence gate + re-encoded custom). BinAuth claimant kept as
audit/defense layer. Direct-to-status UI (CONNECTED + server timer, no
Continue tap) rides the same gate; legacy two-step kept as fallback.
Full story + live portal proof (`TEST-PORTAL` ALLOW/rebind,
`NOPE-PORTAL` DENY + preauth hold, 6h00m + `10240/10240` daemon record):
`STAGE2C_BUILD.md` §7–§11. EAP deploy of the theme change is a separate
approved step; backend/API unchanged by it.
