# openNDS voucher portal — repo reading guide (START HERE)

> If you are an AI reviewer (ChatGPT): read this file first, then follow the
> order below. Source of truth for device behavior is `../opennds/` (copies
> from the EAP225-Outdoor V3, openNDS 10.3.1-r3 — do NOT assume upstream parity).
> Target: OpenWrt 25.12.x, 128 MB RAM / 16 MB flash, gateway `10.0.0.1`,
> `gatewayfqdn=status.client`, MHD `:2050`, LuCI `:80`.

## Where things stand

* **Stage 1 DONE** — CPD-safe voucher login ThemeSpec, proven on Android CPD + Chrome.
* **Stage 2 DONE (local, NOT deployed to EAP)** — real voucher validation +
  initial session authorization (backend + EAP claimant + tests).
* **Stage 3 DESIGN ONLY** — unified `status.client` entry + custom status +
  pause/resume. Approved as a target, NOT approved for implementation.

## Read order for reviewers

1. `10-stage2-validation.md` — current implementation: scope, files, decisions,
   EAP↔backend contract, test results, what is still manual.
2. `09-stage2-unified-entrypoint.md` — Stage 3 design record WITH the 6 approved
   corrections (internal-PreAuth, paused re-identification, dual-state CONNECTED,
   routing trace, one-backend CPD+Chrome, port-80 lock).
3. `08-stage1-checks.md` — Stage 1 test evidence.
4. `01-…-07-….md` — ORIGINAL static-analysis snapshot (Q1–Q19 + A–E). Historical;
   where it conflicts with 08/09/10 or the root `STAGE*_BUILD.md` files, the
   newer documents win. In particular: `PORTAL-TEST` is RETIRED (absent from the
   backend ⇒ deny), and `custombinauth` is no longer a stub in Stage 2
   (`../custombinauth.voucher.sh` replaces it at deploy; `../opennds/` keeps the
   pristine stub copy).
5. Root `../STAGE2_BUILD.md` — full Stage 2 build record + manual deploy/rollback
   (not run). Root `../STAGE1_BUILD.md` / `../STAGE1_PLAN_README.md` — Stage 1 history.

## Code map (repo root `../`)

* `theme_voucher.sh` — Stage 1/2 login ThemeSpec (inline CSS, no JS, no ToS).
* `custombinauth.voucher.sh` — Stage 2 EAP claimant, deploys as
  `/usr/lib/opennds/custombinauth.sh`. `auth_client`-only, fail-closed.
* `backend/` — `api.py` (one validation function; `POST /claim` line protocol +
  `GET /session` JSON + `/healthz`), `schema.sql` (PostgreSQL),
  `seed.sql` (LOCAL TEST rows only, no secrets), `test_api.py` (9 unittests).
* `tests/custombinauth_test.sh` — 11-case shell harness, all PASS locally.
* `opennds/` — pristine device copies. Never edited; reference only.
* `index.html` / `index.css` / `status.html` — approved UI mockups (design source,
  not served raw; `index.css:1` fence is invalid if served raw).

## Changelog

* Unified entry: `client_params_voucher.sh` (status.client auto-forward/fallback
  + custom status, err511 also forwards; HTTP 511 semantics untouched);
  `tests/client_params_voucher_test.sh` 31/31; deploy = file content into
  stock path + backup (UCI key unsupported); see `STAGE2C_BUILD.md` §12–14.
  Deployed live + proven.
* Error vocabulary + loading UX: reason-mapped denied pages (expired/in-use/
  invalid/retry, anti-enumeration asserted), masked deny audit, CSS spinner +
  disabled submit via progressive-only inline script; harness 52/52; undeployed.
* Inline login errors: failures re-render the login card with code preserved
  (separate fail page removed); harness now 57/57; undeployed.
* Live counter: `data-remaining` + deadline countdown on both status pages
  (static fallback intact, `node --check` clean); undeployed.
* Post-auth redirect: success hands the browser to `http://10.0.0.1/`
  (meta + JS + fallback, no voucher string in output); undeployed.
* Direct-to-status: `theme_voucher.sh` CONNECT now authenticates immediately and
  renders custom status (CONNECTED + remaining + own voucher, no Continue tap);
  legacy thankyou/landing kept as fallback; `tests/theme_voucher_test.sh` 25/25;
  undeployed (see `STAGE2C_BUILD.md` §9).
* Stage 2: `custombinauth.voucher.sh` + `backend/` + `tests/` added; `theme_voucher.sh`
  markers moved Stage 1-bypass → Stage 2-validation (flow identical);
  `docs/09` corrected per verdict (6 items); this index rewritten; `10` added.
* Stage 1: `theme_voucher.sh` + `docs/08` + root `STAGE1_*`.
* Base: `opennds/` copies + `docs/01-07` analysis + UI mockups.

## Constraints every reviewer must respect

* One backend, one validation function, one voucher table for CPD AND Chrome.
* Entry/status layer is render-only; sole grant path is
  ThemeSpec → `auth_log()` → `ndsctl auth` → `binauth_log.sh` → `custombinauth` → backend.
* MAC/IP/token/URL-params are never identity; backend authoritative; generic fail
  pages (no invalid-vs-expired oracle); no voucher/custom in visible text.
* Port 80 / LuCI / firewall / DHCP untouched. No EAP deploy without approval.
  No secrets in this repo (PSK is env/file-only, 0600, never committed).
