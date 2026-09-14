# STAGE 2C — Production BinAuth Integration (final record)

> Verdict: **STAGE 2C — BACKEND PASS, PRODUCTION-GATE OPEN (not a clean PASS).**
> Phases A–I proven with evidence below. J/K + one production anomaly need
> answers before the PASS stamp. No implementation changed in Phase L.
> Nothing deployed beyond the recorded state. No Stage 3.

## 1. Deployed state (recorded, read-only)

| Item | Value |
|---|---|
| EAP | TP-Link EAP225-Outdoor V3, OpenWrt, openNDS 10.3.1, `br-lan`, MHD `10.0.0.1:2050` |
| theme_voucher.sh (EAP) | `6b2121e2…ebba5c4` — MATCHES frozen Stage 1 hash |
| custombinauth.sh (EAP) | `50b15ed3…7ea92d` — MATCHES tested source (`root:root 755`) |
| binauth_log.sh (EAP) | `52212f73…14a8ce4` — stock, intact |
| client_params.sh (EAP) | `85e73b01…ed368e9f32` — stock, intact |
| libopennds.sh (EAP) | `5909844b…618ff1896` — stock, intact |
| Backup | `/usr/lib/opennds/custombinauth.sh.bak-20260913-013501` (449 B stub, `16e4ff0b…`) |
| UCI delta vs Stage 1 | ONE addition: `voucher_api_url='http://192.168.100.49:8080/claim'`; `login_option_enabled=3`, `themespec_path`, faskey untouched |
| PSK file | `/etc/opennds/voucher_psk`, `root:root 600`, 64 B, hash-verified vs production |
| API route used | EAP → wired `192.168.100.49:8080` (NOT Wi-Fi `.107`: Ubuntu `wlo1` is itself a captive client `e8:6f:38:c4:5f:d9`, and openNDS filters EAP→preauth-client traffic) |
| openNDS health | running, MHD listening, BinAuth = stock `binauth_log.sh` |

## 2. Phase results A–I (all PASS, evidence on file)

* A: status/UCI/scripts/checksums recorded; BinAuth default path confirmed.
* B: theme hash `6b2121e2…` verified on-EAP before deploy.
* C: timestamped stub backup, hashes + perms recorded.
* D/E: `scp` unavailable (no sftp-server) → pushed over `ssh cat`; perms reset to stock `755`; deployed sha == source sha; EAP `sh -n` clean.
* F/G: no `PORTAL-TEST`/debug in deployed file; UCI URL set+committed; reload clean (daemon uptime continuous, no restart needed — script is sourced per-event).
* Live defects found+fixed (both proven in production conditions):
  1. **Chunked POST** — EAP `uclient-fetch` sends `--post-data` as `Transfer-Encoding: chunked` with no `Content-Length`; server read empty body → every claim denied. Fixed server-side (`_read_body`, bounded de-chunking) + 2 regression tests. No EAP/protocol change.
  2. **`rev: not found`** — busybox lacks `rev` (masked-logging only, non-fatal). POSIX `cut` range + static busybox-tool gate in harness.
* I-1 ALLOW `360/10240/10240` exit 0 · I-2 unknown DENY exit 1 · I-3 same-MAC rerequest ALLOW (`rerequest` audit, no rebind) · I-4 new-MAC rebind ALLOW + `rebound` audit, binding moved · I-5 API-down DENY + full recovery ALLOW. Backend rows/events verified after each step.
* Guard: manifest + scope + accrual + ndsctl-surface all PASS (local + EAP hashes agree).

## 3. OPEN — production grant outside the voucher path (blocks clean PASS)

At ~01:53 EAP time a real randomized-MAC client (`32:09:8a:5d:13:11`, `cpi_url`,
i.e. browser-driven portal flow) became **Authenticated carrying
`custom=voucher=PORTAL-TEST2`**, session = global defaults (**24 h, null rate
limits** — NOT our `360/10240` policy), ~52 MB flowing.

Why this is NOT our voucher path:
* `PORTAL-TEST2` exists NOWHERE in PostgreSQL (no row, no ALLOW, and not even a
  `DENY unknown` event — a BinAuth `auth_client` deny would have written one).
* `binauthlog.log` holds NO `auth_client` entry for this MAC at 01:53 (only an
  earlier 01:47 `ndsctl_auth` with `PORTAL-TEST` and a 01:49 `client_deauth`).
* openNDS log shows a bare `Authenticating …` at 01:53:06 with no BinAuth
  involvement; preemptive-auth queue dir is empty and no preemptivemac/trust
  lists exist in UCI — mechanism unconfirmed, possibly operator-driven
  (`ndsctl` works from shell) or an openNDS auto-path this project has not
  characterized.

Consequences:
* J/K cannot be marked from this observation: Internet works on the device, but
  NOT demonstrably through voucher validation (acceptance #9–#12, #15–#16 open).
* Related finding: our script passes `ndsctl_auth`-method calls through with
  default ALLOW (only `auth_client` is gated). That is local-shell-only attack
  surface, but it is a fail-open worth an explicit policy decision — NOT changed
  here (would risk breaking preemptive/authmon flows).

Questions for the operator (answers unblock PASS):
1. Was the 01:47 `ndsctl_auth` (PORTAL-TEST) and the 01:53 activity (PORTAL-TEST2)
   your manual testing? If yes, J/K procedure should be re-run cleanly with
   PORTAL-TEST and backend events checked per step.
2. Is preemptive/auto-auth behavior on this EAP acceptable during Stage 2C, or
   must unknown devices stay fully captive until a voucher ALLOW?
3. Policy for `ndsctl_auth` method in `custombinauth`: keep passthrough (admin
   tool stays working) or deny-by-default?

## 4. Rollback procedure (ready, tested path — NOT executed)

```sh
# on the EAP (root):
cp -p /usr/lib/opennds/custombinauth.sh.bak-20260913-013501 /usr/lib/opennds/custombinauth.sh
chmod 755 /usr/lib/opennds/custombinauth.sh
chown root:root /usr/lib/opennds/custombinauth.sh
uci delete opennds.@opennds[0].voucher_api_url
uci commit opennds
rm -f /etc/opennds/voucher_psk
sh -n /usr/lib/opennds/custombinauth.sh && sha256sum /usr/lib/opennds/custombinauth.sh
# expect 16e4ff0b… (stock stub); then:
/etc/init.d/opennds reload
ndsctl status   # expect healthy, BinAuth = binauth_log.sh
# verify: Stage 1 portal renders; voucher login returns to stub behavior
# (allow-by-default); keep backup file in place, do NOT delete it.
```

Effect: stock stub restored (open allow), URL option removed, PSK material gone
from EAP, no other file touched. Ubuntu API/PostgreSQL need no changes (idle).

## 5. Files/config changed (complete list)

* EAP: `/usr/lib/opennds/custombinauth.sh` (stub→`50b15ed3…`), +1 UCI option
  (`voucher_api_url`), +1 backup file, +1 PSK file (`600`). NOTHING else.
* Repo (uncommitted — held pending J/K + anomaly resolution): chunked-body fix
  + tests, `rev` fix + portability gate, this file. No EAP/stage-1 files differ
  from their recorded hashes.

## 6. Acceptance checklist (honest marks)

1. Theme hash unchanged — YES (`6b2121e2…`).
2. UCI intact except required BinAuth setting — YES.
3. `binauth_log.sh` intact — YES.
4. Tested script deployed — YES (`50b15ed3…` both sides).
5. Checksums match — YES.
6. Permissions correct — YES (`root:root 755`, PSK `600`).
7. API reachable — YES (wired path; Wi-Fi `.107` unusable by design, documented).
8. PostgreSQL reachable — YES.
9. Known voucher ALLOW — YES (direct BinAuth proof).
10. Unknown DENY — YES.
11. Same-MAC correct — YES (`rerequest`, no rebind).
12. Rebind correct — YES (`rebound` + binding moved).
13. Outage DENY — YES (live).
14. Recovery ALLOW — YES (live).
15. Android CPD — OPEN (see §3).
16. Chrome — OPEN (see §3).
17. No secrets exposed — YES (hash-compare + redacted transport only).
18. No Stage 1 modified — YES.
19. No Stage 3 introduced — YES.
20. Rollback ready — YES (§4, backup verified present).

## 7. Post-report fix: close the non-`auth_client` grant path (LOCAL ONLY)

Trigger: production showed a 24 h/default-limits grant carrying
`voucher=PORTAL-TEST2` with zero backend events and zero BinAuth involvement —
operator-confirmed manual `ndsctl` testing, but a real fail-open class:
`custombinauth` validated ONLY `auth_client`; every other method fell through
with parent allow-defaults.

Fix (`custombinauth.voucher.sh`, local sha `cd15b276…`, NOT yet deployed):
shared `vbackend_claim()` for all paths; `*deauth` still pure passthrough;
any other method carrying a `voucher=` claim is fully validated (neutral
metadata: strict-or-empty MAC, empty ip/token — slots unreliable there);
absent claim → abstain with defaults untouched; malformed claim → deny;
secondary methods confirm-or-deny only (stranger-owned EVICT → abstain,
defaults restored; only `auth_client` may rebind). Syslog now tags
`method=` for forensics.

Proof locally: harness 41/41 (33 legacy UNCHANGED — `auth_client` behavior
identical — + 8 method cases incl. abstain), `test_api` 11/11, `test_pg` 6/6,
`test_server` 5/5, guard PASS (manifest + scope + accrual + ndsctl-surface).

Blocked deploy: EAP `10.0.0.1` stopped answering L3 (ARP REACHABLE, Wi-Fi
associated, zero ping/SSH) during rollout — backup of deployed `50b15ed3…`
NOT yet taken, fix NOT pushed, live re-verify NOT run. Per stop rules all
EAP work halted; no improvisation. Resume with: backup → push → hash →
T1/T2 + `ndsctl_auth`-method live cases → clean J/K with PORTAL-TEST.

## 8. Recovery + production close-out (EAP returned, fix deployed + proven)

Root cause of the 24 h ghost CONFIRMED: deployed `binauth_log.sh` was
byte-identical to the `custombinauth` snippet (`cd15b276…`) — no `$action`,
no `$custom`, no defaults, no quota echo — so every BinAuth call abstained
into daemon defaults (24 h, unlimited, allow). Remediation in order:
R1 restored stock `binauth_log.sh` from hash-verified backup (`52212f73…`,
`sh -n` clean); R2 timestamp-backed-up superseded `custombinauth.sh`
(`50b15ed3…` kept) and deployed tested `cd15b276…` at the correct slot
(hash match both sides, `sh -n` clean, no daemon restart — scripts exec
per event).

Live on-EAP proof (direct BinAuth invocations + backend rows checked):
T1 PORTAL-TEST ALLOW `360/10240/10240` exit 0 · T2 unknown DENY exit 1 ·
N1 `ndsctl_auth`+valid voucher → ALLOW quotas exit 0 · N2 `ndsctl_auth`+
unknown → DENY exit 1 (the PORTAL-TEST2 hole class, closed at script level) ·
N3 no-custom → passthrough defaults exit 0 (preemptive/admin preserved).
EAP syslog shows `method=auth`/`method=auth_client` decisions with masked
vouchers; backend audit rows match every run. Stale PORTAL-TEST2 session
deauthenticated and gone from the client list.

Positional mapping (§14 verdict): header layout (`$2/$5/$6/$7`) KEPT — the
docs variant belongs to a username/password login mode this deployment does
not run, the vendor ships that header with this daemon, and strict gates fail
closed on mismatch. Empirical gate stands: first J/K portal auth must show
backend event mac/ip/token equal to `ndsctl`-known values, else STOP.

OPEN: clean J/K device runs with PORTAL-TEST + positional proof; then stamp
PASS and commit (implementation + this record held uncommitted until then).

## 9. Direct-to-status portal flow (LOCAL ONLY, undeployed)

Request: after CONNECT, authenticate immediately and render the custom status
UI — no intermediate Continue tap (CPD-friendly). Change is ThemeSpec-only
(`theme_voucher.sh` → new sha recorded in `tests/stage1_manifest.sha256`;
core openNDS files untouched):
ENFORCEMENT REDESIGN (daemon honors request quotas, may skip BinAuth on the
FAS path — proven by debug-trace forensics): new `voucher_api_claim()`
pre-validates through the backend BEFORE any auth call and rebuilds `$quotas`
from the response; `voucher_status_page()` and legacy `landing_page()` (now
also presence-gated + re-encoded) call `auth_log` ONLY on ALLOW with explicit
policy quotas, else render generic fail with NO grant possible (fail closed by
omission). Legacy thankyou/landing kept as hardened fallback.

Proof locally: `tests/theme_voucher_test.sh` 31/31 (login unchanged, direct
status with deterministic timer, voucher shown once, ALLOW→auth-called with
`360|10240|10240`, DENY/fetch-fail→auth SKIPPED, legacy landing gated on
voucher+ALLOW, CPD-safety scans) + full regression (`custombinauth` 41/41,
guard PASS, `test_api` 11/11, `test_pg` 6/6, `test_server` 5/5). EAP deploy
(backup → push → hash → live device re-verify incl. unknown-voucher portal
proof) is a separate approved step, not done here.

## 10. Live portal proof via wlo1 curl FAS flow (no device needed)

Driven end-to-end through captive redirect → preauth → voucher submit:
* Unknown (`NOPE-PORTAL`) → `REQUEST FAILED`, client held preauth (no session),
  backend `DENY unknown` with true client MAC/IP (positional mapping proven).
* Valid (`TEST-PORTAL`, seeded NEW for the test) → `CONNECTED` + `05:59:58`
  timer + own code shown once, backend `ALLOW fresh 21600`, daemon session
  exactly 6h00m with `10240/10240` thresholds. Test client deauthed after;
  daemon debug reset 1. `TEST-PORTAL` row remains (labeled test artifact).

## 11. Deferred (explicitly not this stage)

* Upload-rate calibration (`UP_KBPS` reverted to documented 10240 after an
  unproven 3500 probe; downlink shaping verified at 9.98/10, uplink needs a
  controlled retest).
* 5 GHz preference/band steering (client camped 2.4G HT20 while 5G VHT80 up;
  Wi-Fi config frozen).
* EAP briefly unreachable twice (link/ARP up, L3 silent, self-recovered) —
  cause undetermined, watch item, no config changed for it.

## 12. Unified status.client entry (LOCAL ONLY, undeployed)

Request: browsers visiting the portal must land on voucher login with zero
extra clicks (no stock Session Status), authed users get custom status.
New `client_params_voucher.sh` (fork of stock 354-line handler; err511/busy/
helpers/bottom-harness byte-verified identical): `status` branch dispatches on
live `ndsctl json` — unauthenticated/preauth/expired/unknown → auto-forward
page (meta-refresh + fallback form to stock `$url/login`, which mints the FAS
query for the ThemeSpec); authenticated + live session → self-contained
custom status (CONNECTED, server timer, own voucher via b64 custom decode,
Logout kept); `custom` added to the json allowlist. Render-only, no grant
capability, no CPD-path change, no port/firewall/DHCP change. Deploy =
new file + `uci set opennds.@opennds[0].statuspath=...` (reversible; `strings`
confirms daemon support; stock file never overwritten).
Proof locally: `tests/client_params_voucher_test.sh` 28/28 (forward/status/
expired/json-fail/custom-variants/err511-identity/busy/CPD-safety).
Deploy + live curl proof (preauth forward chain, authed status) is a separate
approved step, not done here.

## 13. Unified entry v2: err511 also auto-forwards (LOCAL ONLY, undeployed)

Correction from live-model review: preauth browsers are served the `err511`
branch (not `status`), so the user's actual complaint (stock "To login,
Continue" page) lives there. `body()` err511 branch removed; dispatch now
sends err511 to the same auto-forward page (meta-refresh + fallback button).
HTTP 511 + daemon redirect semantics untouched (MHD-owned) → CPD protocol
unaffected. Proof: harness 31/31 incl. old-entry-gone + err511-dispatch +
verbatim-stock-region checks.

## 14. Unified entry deployed + proven live (no restart needed)

Deploy: stock `client_params.sh` backed up (`.bak-20260913-041810`, sha match);
fork content live at BOTH `/usr/lib/opennds/client_params_voucher.sh` and
`client_params.sh` (identical sha, perms stock, syntax clean) + UCI
`statuspath` set+committed for restart-resilience. Findings en route:
`statuspath` UCI key IS consumed (daemon latched it at restart — earlier
"unsupported" reading retracted); `reload` does NOT re-read it but per-hit
script exec means file changes apply instantly; reload AND restart both clear
client sessions (operational fact); an operator-deployed early draft was
already live (backed up, superseded).
Live proof (curl FAS over Wi-Fi, no device needed): preauth
`status.client/` renders forward page (brand + meta-refresh + fallback form,
zero stock text) -> `/login` 302s to fresh-fas preauth -> voucher UI;
CPD POST still gets HTTP 511; authed `status.client/` renders custom status
(CONNECTED + own code + live `05:59:49` timer counting down + Logout), zero
stock dump. Test client deauthed after; daemon debug reset 1.

## 12. Daemon-restart restores sessions WITHOUT rates (observed, by design)

`restart` (unlike `reload`) runs auth_restore from RAM authlog: sessions come
back with remaining time but UCI-default (null) rates — NOT the voucher policy.
Observed: post-restart `.200` session 6h/null-rates despite a fresh backend
ALLOW seconds earlier whose in-flight auth died in the restart. Fix is
procedural, not code: after any daemon restart, clients re-run the portal once
(fresh claim re-applies 360/10240). Watch item: multiple unexplained daemon
restarts in one day (02:16, 04:16 operator, 04:29 unknown actor) — confirm who
restarted; if nobody did, treat as instability (power/thermal/OOM) to chase.

## 15. Voucher error vocabulary + submit loading state (LOCAL ONLY, undeployed)

Request: distinct failure UI (expired / in-use / limit / invalid) and a
loading state for the multi-second backend wait (no double-submits, visible
feedback). Implemented in `theme_voucher.sh` only (no backend change — all
reason codes already existed in the `/claim` contract):
* Claim captures a failure class; the denied page maps it through a fixed
  vocabulary: expired -> "VOUCHER EXPIRED", paused -> "VOUCHER IN USE",
  missing code -> prompt, transport/config/garbled -> generic retry, and
  unknown/disabled/malformed share ONE "INVALID VOUCHER" text
  (anti-enumeration: byte-identical pages, asserted in tests). Denied attempts
  write a masked server-side log line (reason + client MAC only).
* Loading state is progressive enhancement only: CSS spinner + disabled +
  relabel via one tiny inline ES5 script on every submit form. Where JS is
  blocked the form submits normally; correctness never depends on it because
  the backend claim is idempotent (rerequest cannot double-spend).
* Policy note (no change made): a hard "used from another device" DENY would
  contradict the approved evict-allow rebind (new phone / rotated MAC would
  lock out); `paused` rows are the only truthful in-use signal and keep the
  approved semantics. Volume "limit reached" has no backing counter (time
  limit IS the expired message).
Proof: `tests/theme_voucher_test.sh` 52/52 (reason texts, byte-identical
unknown/invalid/disabled, masked deny-log codes, no-fetch on malformed,
loading markup+CSS+script presence, no-JS-independent rendering) + full
regression green. Deploy on approval.

## 16. Portal render speedup (deployed + measured)

Complaint: ~4 s from portal visit to login UI. Measured: forward page ~1.1 s
+ ThemeSpec render ~5.5 s. Root causes: (1) `get_client_interface.sh`
(~1.4 s ping sweep) runs on EVERY preauth render for `$client_zone`, which
our UI never displays; (2) hop relied on meta-refresh timing alone.
Fixes (both files, both live): theme presets `client_zone="Wi-Fi"`
(documented; BinAuth keeps full per-auth zone detection), forward page adds
instant JS navigation (meta + button survive as fallback). Measured after:
forward ~1.4 s with booster present, preauth render **2.64 s** (~52% faster).
Remaining ~2.6 s is stock-core fork overhead on the EAP CPU (frozen).
Deployed with per-file backups, hash-verified, syntax-clean; no restart.

## 17. Inline login errors + submit loading state (LOCAL ONLY, undeployed)

Request: (a) voucher failures render inline on the login card (code preserved
for correction) instead of a separate error page; (b) submit buttons show a
spinner + disabled state across the multi-second backend wait.
* (a) `voucher_error_text()` maps the existing claim classes to the fixed
  vocabulary (expired / in-use / required / invalid / retry; unknown, disabled
  and malformed byte-identical anti-enumeration); both deny paths render
  `login_form` with an inline banner. Separate fail page deleted. Deny audit
  retained (masked reason + MAC).
* (b) CSS spinner + `:disabled` + one tiny inline ES5 `voucherSubmit` on every
  submit form (CONNECT/Continue/Try-again). Progressive enhancement ONLY:
  inert where JS is blocked; correctness rests on the idempotent backend
  claim (duplicate submit = harmless rerequest), asserted by preserved
  no-JS render tests.
* Policy note (unchanged): hard "used from another device" DENY would break
  the approved evict-allow rebind (new phone / rotated MAC lockout); `paused`
  rows are the only truthful in-use signal. Volume "limit reached" has no
  backing counter (time limit IS the expired message).
Proof: harness 57/57 (inline banner, preserved code, reason texts, identical
unknown/invalid/disabled, masked log codes, loading markup/CSS/script,
no-JS rendering) + full regression green. Deploy on approval.

## 18. Live remaining-time counter (deployed + proven)

Request: remaining time went stale until manual refresh. Both status pages now
embed server seconds (`data-remaining`, digit-guarded at render) plus one tiny
inline ES5 countdown (frozen deadline, self-correcting, freezes at 00:00:00
with no auto-action). Progressive enhancement only: blocked scripts leave the
exact previous static display. Unlimited sessions still omit the timer.
Proof: deterministic `data-remaining="45678"` + `12:41:18` static agreement,
single-script assertions, `node --check` over every inline script block,
no-JS fallback equivalence; theme 61/61, entry 37/37, full regression green.

## 19. Forward loading state (paint-first navigation)

Complaint: a black gap between portal visit and login render. Cause: the
instant-navigation script ran at head-parse, before first paint, leaving a
blank (dark-mode black) gap during the ~2.6 s server render. Fix: the forward
page now paints a loading state first (CREATING SESSION + CSS spinner + light
`html` background + `color-scheme: light`), navigating on window `load`, with
meta-refresh + manual button unchanged underneath. Nothing else touched.

## 20. Forward button removed (owner request, deployed + proven)

The fallback Continue button is gone from the forward page: loading card +
spinner navigate via load-event JS with meta-refresh underneath. No-JS
clients still forward via meta; CPD unaffected (ignores bodies). Only clients
with both JS and meta disabled would strand (effectively nonexistent).
Deployed both handler paths (hash-verified, backups kept), live page shows
CREATING SESSION with zero buttons.

## 21. Post-auth redirect to the clean entry (deployed + proven)

Request: after CONNECT + successful auth, hand the browser to
`http://10.0.0.1/` instead of sitting on the long preauth URL (which also
leaves the voucher code in history). Both success renders (direct +
legacy) emit a minimal interstitial (brand + CONNECTED + spinner, JS-on-load
+ meta-refresh 0, no manual button per owner request) to `http://10.0.0.1/`,
which serves the live custom status for the authed client. No voucher string
and no timer block in the interstitial output. Fail/deny paths unchanged.
Proof locally: redirect target/meta/JS assertions, no-button assertion,
no-voucher-leak assertions, `node --check` clean; theme 58/58 + full
regression green. Proven live: submit returns the buttonless interstitial;
following it renders custom status with live timer; test client deauthed.
