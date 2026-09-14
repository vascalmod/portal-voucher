# A–E. Knowledge, unknowns, architecture, files, tests

## A. What we already know

Full local flow, variable sets, `custom`/`encode_custom` voucher channel, BinAuth override contract (`session_length/rates/quotas/exitlevel`), status mechanics, `auth/deauth/json` roles, RAM-only state, CPD no-external-CSS/JS constraint, 3-file change surface — all grounded in line refs in `01`-`06`.

Goal mapping: local MHD UI + `₱5/6h/10 Mbps` + true pause/resume + minimal flash is implementable without new frameworks.

## B. Still unknown (needs EAP tests)

* `uci show opennds` effective `themespec_path, statuspath, sessiontimeout, rates, faskey, preemptivemac, log_mountpoint, gatewayport/fqdn`.
* `ndsctl json` exact JSON for Preauthenticated vs Authenticated (includes `custom`? rate/quota units? `session_end` epoch vs `null`?).
* `sessiontimeout`/rate units and 10 Mbps mapping; minute rounding.
* Deauth `$5/$6` semantics (actual end vs original expiry).
* Reachability of `status.client` + `opennds_deny` + `/opennds_preauth/` in ACTIVE/PAUSED/unauth states.
* CPD render of inlined CSS/no-JS portal on target phones.
* EAP→Ubuntu egress via `192.168.100.1` (latency, `uclient-fetch` availability).

## C. Recommended architecture

Local MHD UI + external state:

* New `theme_voucher.sh` (login) + forked status handler + `custombinauth.sh` sole EAP policy/accounting calling minimal Ubuntu API/Postgres (authoritative `remaining`, single-session eviction).
* `ndsctl deauth` = pause (freeze), `ndsctl auth remaining+rates` = resume.
* No port/firewall/LuCI changes now; no RADIUS/Mendyfi/Omada/Vercel/Supabase.

State machine: NEW/Preauthenticated→login; `auth_client` allow→ACTIVE; `deauth`→PAUSED; re-auth→ACTIVE; `remaining≤0`→EXPIRED→login/expired.

## D. Files to create/modify

* Create: `theme_voucher.sh`, `client_params_voucher.sh`, Ubuntu API + SQL.
* Modify (later, EAP): `custombinauth.sh` (stub→real), `uci opennds` (`themespec_path, statuspath, faskey, rates/timeout, preemptivemac cleared`).
* Do not modify: `libopennds.sh`, `binauth_log.sh`, LuCI/uhttpd, firewall/DHCP/NAT — until §E tests pass.

## E. Pre-implementation EAP tests (read-only first)

1. `uci show opennds; cat /etc/config/opennds; ndsctl status`.
2. `ndsctl json <preauth-mac/ip>` vs post-`ndsctl auth` json — capture JSON, confirm `custom/state/session_*`.
3. `ndsctl auth <test-mac> 5 1024 10240 0 0 <b64test>` → verify units, then `ndsctl deauth` → capture `binauthlog.log/authlog.log` + syslog `$3-$8`.
4. From unauth + authed + deauthed: `curl -i http://10.0.0.1:2050/ http://status.client/ http://10.0.0.1/` + DHCP 114 check; portal reachable all states, LuCI untouched.
5. CPD test: inline-CSS/no-JS preauth mock via current ThemeSpec; verify no external fetch.
6. EAP→Ubuntu: `uclient-fetch`/ping via WAN, latency; `df -h; free; logread | grep opennds`.
7. Confirm `preemptivemac` contents and plan to clear; check `faskey` (rotate if empty/default).
