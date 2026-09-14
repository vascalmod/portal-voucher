# 17–19. Security, constraints, bugs

## 17. Security / shell-injection risks

* `parse_variables` (`libopennds.sh:517-536`, `client_params.sh:73-92`) does `eval $var="..."` after `htmlentityencode` (`640-662`: `"` `;` `>` `<` `%` `'` `` ` `` `?` `$` `/` `\`). Treat `$voucher` untrusted: `htmlentitydecode` → allowlist `^[A-Z0-9-]{4,20}$`, uppercase, trim → reject otherwise. Never `eval` it; never interpolate into `eval ndsctl "$ndsctlcmd"` (`304-309`) or SQL/shell unquoted.
* CID files are sourced (`. $ciddir/$cid` at `libopennds.sh:445`, `. $mountpoint/ndscids/$cidfile` at `binauth_log.sh:235`; written `libopennds.sh:484-488`). Do not write raw voucher into sourced files; keep encoded form there, decoded copy only in non-sourced cache/API payload.
* `custombinauth.sh` runs as root. API key `0600`, HTTPS (or LAN PSK) EAP→Ubuntu, rate-limit attempts, log `mac/ip/token/client_type/zone`, avoid leaking valid-vs-consumed distinction beyond UX need.
* Reflected XSS: echo `$voucher` only via `htmlentityencode`.
* Empty `faskey` (`get_key_from_config:1111-1120`) makes `rhid=sha256(hid)` predictable — set strong `faskey` before production.
* `do_ndsctl` uses `eval` (`libopennds.sh:309`, `authmon.sh:19`, `client_params.sh:14`); voucher must be sanitized before any `auth/deauth` string construction.

## 18. Flash/RAM constraints (16 MB / 128 MB)

* Logs already tmpfs (`binauth_log.sh:87-123`, `libopennds.sh:538-576`); `write_log:763-776` caps `max_log_entries` (default 100). Keep. Never per-second flash writes (jffs2 wear + overlay).
* EAP transient cache in `/tmp` only; Postgres/Ubuntu authoritative. Event-only sync, no polling by default. `get_image/data_file` caches `$mountpoint/ndsremote|ndsdata` (RAM) — prefer zero remote assets; inline CSS.
* Deps: busybox `sh/awk/sed/uclient-fetch/nft/ip/iw` (`get_client_interface.sh:11-23`). No Python/PHP hot path (`post-request.php` is remote-FAS only). Watch `free`/`df -h`; `preemptivemac`/`auth_restore` loops and `do_ndsctl` retries spike processes on 128 MB.

## 19. Bugs / wrong assumptions in notes

1. `index.css:1` fence breaks raw serving; forms lack `action="/opennds_preauth/"`, `method="get"`, `fas` hidden (cf. `theme_user-email-login-basic.sh:94-98,152-157`); `status.html:55` PAUSE inert (cf. `client_params.sh:217,223`).
2. `encode_custom()` not automatic (`libopennds.sh:2197-2200` commented; themes call explicitly, e.g. `theme_user-email-login-basic.sh:142`). Click-to-continue never sets `binauth_custom`.
3. Stock status omits `custom` (`client_params.sh:103-107`); `grep/awk -F'"'` parse (`108`) fragile, `null→Unlimited` (`110-112`), `date -d @...` (`130-138`) fails on `Unlimited/0` — guard in fork.
4. `theme_user-email-login-custom-placeholders.sh:156-157` stray `urldecode "$test_variable2"` — do not copy.
5. `check_authenticated` (`578-597`) keys on FAS `$status`, not general authed→status redirect; needs live verification.
6. `binauth_log.sh:231` `grep -r "$2"` can match multiple CIDs; `client_params.sh:31-51` vs `binauth_log.sh:17-44` `get_client_zone` differ (cached `$clientif` vs live script).
7. Preemptive auth enabled bypasses vouchers — must clear `preemptivemac` list (`2014-2095`).
8. `session_length` is minutes (`auth_restore:1741-1742` `/60`), not seconds; 10 Mbps units and `json custom` visibility need live confirmation. `session_end=null` for preauth is expected.
