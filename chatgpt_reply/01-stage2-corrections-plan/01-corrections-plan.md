# Stage 2 corrections plan (plan-only, nothing changed)

## Probe results (read-only, before planning)

* `backend/api.py:72-76` always opens SQLite; `api.py:254` hard-codes `127.0.0.1`.
* No `psycopg`/`psycopg2` installed; no local postgres binaries — but `docker`
  exists (only `hello-world` + Omada images cached, no postgres image).
* `backend/schema.sql` is already PostgreSQL-typed (`TIMESTAMPTZ`, five states)
  but has no CHECK constraints.
* Stage 1 files verified pristine.

## 1. `backend/schema.sql` (small, surgical)

* Add: `CHECK (total_secs >= 0)`, `CHECK (used_secs >= 0)`,
  `CHECK (used_secs <= total_secs)`.
* Keep: `vouchers`/`events` shape, all columns (`code…created_at`), `TIMESTAMPTZ`
  + UTC `now()` defaults, `NEW/ACTIVE/PAUSED/EXPIRED/DISABLED`, and the
  Stage 3 preparation fields (`used_secs`, `resume_ts`, `PAUSED`) unused.
* Add a header comment: this file is the production contract `api.py` must load
  verbatim in pg mode.

## 2. `backend/api.py` (rework, stdlib + one driver)

* **Backend selection — explicit, no silent fallback.** `DATABASE_URL` set
  (postgres scheme) → PostgreSQL only. Driver import (`psycopg` v3,
  `pip install "psycopg[binary]"`) or DB unreachable/misconfigured → log a clear
  server-side error, mark backend down, **all `/claim` → generic `DENY`**,
  never SQLite. `DATABASE_URL` unset + `VOUCHER_DB` set → SQLite explicit-dev
  mode. Neither set → refuse startup with a clear error.
* **One adapter, one logic.** `claim_voucher(conn, code, mac, ip, token, now=None)`
  signature kept. All SQL written once with `%s` placeholders; a tiny `execute()`
  wrapper translates to `?` on sqlite and normalizes rows to dicts (`dict_row`
  on pg). Transactions: pg `SELECT … WHERE code=%s FOR UPDATE` in a transaction
  block; sqlite keeps `BEGIN IMMEDIATE` **inside the adapter only**. Timestamps
  DB-side (`now()` / `datetime('now')`), normalized to ISO on output.
* **`HOST` env** (default `127.0.0.1`); production sets `HOST=0.0.0.0` or the
  Ubuntu LAN IP. LAN proof is a test, not prose.
* **No leakage.** Whole request path wrapped: any exception → generic
  `DENY <code>` on `/claim` (generic bodies elsewhere); tracebacks to server log
  only. Response vocabulary stays `ALLOW…` / `DENY <generic-code>`.
* Kept: single validation function, rebind policy (evict-old/allow-new + `EVICT`),
  PAUSED→deny, `used_secs` never accrued, `/session` as-is (EAP keeps `/claim`;
  no statuspath wiring).

## 3. `custombinauth.voucher.sh` (validation hardening, same skeleton)

* **MAC:** strict `XX:XX:XX:XX:XX:XX` (six hex octets), else empty-and-continue.
* **IP:** strict IPv4 quad, each octet 0–255 (covers `10.0.0.0/24`); malformed →
  deny before any fetch.
* **Token:** allowlist `A-Za-z0-9._:-`, length 1–128; empty or anything outside
  (incl. `& = % CR LF`) → deny before any fetch.
* **Reply parsing:** accept only `ALLOW <d+> <d+> <d+>` or plus `EVICT <strict-mac>`
  (exact field count, `$5==EVICT`); digit-only numerics with caps (proposed:
  remaining ≤ 8640000, rates ≤ 1000000; session cap 1440 stays) →
  `session_length=ceil(rem/60)`. Everything else (`ALLOW`, `abc`, `-1`, bad rates,
  `RANDOM`, oversized) → deny.
* Unchanged: fail-closed everywhere, deauth passthrough, masked syslog (no value
  / PSK), async evict hook, no `eval`, positional-args contract from
  `binauth_log.sh:287-298`.

## 4. Tests (prove corrections + freeze Stage 1)

* **New `backend/test_pg.py`** (runs only with `TEST_DATABASE_URL`, else clean
  skip): schema loads from `schema.sql` verbatim; voucher/event insert; rollback
  on failed claim; full matrix (NEW→allow, same-MAC rerequest, rebind+EVICT,
  unknown/invalid/disabled/paused/expired/zero→deny); **concurrency** (threads,
  one voucher → exactly one binding); PSK missing/wrong → deny; malformed → deny;
  DB stopped mid-run → generic deny; no-leak assertions on every body. Pg infra:
  disposable `postgres:16-alpine` container — if the image pull fails in build,
  stop and report instead of faking pg with SQLite.
* **`backend/test_api.py`:** kept as explicit-sqlite suite **plus** a no-silent-
  fallback test (`DATABASE_URL` set + broken driver ⇒ pg attempted, no sqlite
  file created, clean failure).
* **LAN-bind test:** server on `HOST=0.0.0.0` (or box LAN IP), successful `/claim`
  over HTTP to that LAN address — the `EAP225 → Ubuntu LAN IP:PORT` proof shape.
* **`tests/custombinauth_test.sh`:** add all parser vectors (bare `ALLOW`, `abc`,
  `-1`, bad/huge rates, `RANDOM`, bad EVICT mac, `ip`/`token` injections with
  `& = % \r \n` asserting deny and, for pre-network rejects, zero fetch calls).
* **New `tests/stage1_guard.sh`:** sha256 manifest of `theme_voucher.sh`,
  `binauth_log.sh`, `libopennds.sh`, `client_params.sh` (hashes from pristine
  state) plus grep guards (no `uci set`, `statuspath`, `gatewayport`, port-80 /
  `nft` / `iptables` changes in Stage-2 files).

## 5. Done criteria (reported in order after green)

Changed files + `git diff --stat`; counts for `test_api` / `test_pg` / shell /
guard separately, with explicit lines confirming: pg-mode ran (container +
driver versions), fallback test passed, LAN-bind claim succeeded, injection
vectors denied, fail-closed on down/unconfigured/malformed, guard green. Commit
only on green; refresh `STAGE2_BUILD.md`. No EAP commands, no Stage 3, no deploy.
