# 7–11. Persistence, identity, accounting, paused access

## 7. What survives disconnect/reconnect

* Short disconnect (same MAC/IP, before `session_end`/idle timeout): openNDS in-memory entry persists (`session_start` unchanged, `last_active` advances, usage counters accumulate). `auth_log:730` comment: cid file retained until openNDS deletes on deauth/timeout.
* Reboot: nothing. `mountpoint` is tmpfs (`configure_log_location` in `binauth_log.sh:87-123`, `libopennds.sh:538-576` picks `/tmp|/run|/var` via `df tmpfs`). `ndscids/`, `ndslog/binauthlog.log/authlog.log`, `preemptive_auth/` are RAM. `libopennds.sh:2355-2372 clean` deletes them. `auth_restore:1642-1772` can re-auth from `authlog` after restart but only non-deauthed/shutdown entries, still RAM-dependent.
* DHCP/IP change: `json $clientip` breaks; re-resolve by MAC (`libopennds.sh:2542-2568 clientaddress`, `get_client_interface.sh:52-57` via `ip -4 neigh`).
* Voucher `remaining` survives only if stored externally (Ubuntu/Postgres). EAP holds transient cache.

## 8. Voucher identity without permanent MAC

Yes. MAC stays required as `ndsctl` selector (auth/deauth/json take mac|ip|token), but must not be voucher primary key.

Design: `custom` (voucher code) is stored per-client and visible in `ndsctl json` + BinAuth `$7/$8`. Backend keys on `voucher_code`; `mac` is mutable `bound_mac` + `last_ip/token` metadata. Single-session: if voucher has different active MAC at `auth_client`, `deauth` old then allow new (or deny — policy choice). Re-login on new MAC/IP resumes remaining.

Do not use `preemptivemac` list (`libopennds.sh:2014-2095`, `auth_restore`) — purely MAC-based, bypasses vouchers.

## 9. Randomized/private MAC

Problem only if voucher permanently bound to first MAC.

* iOS/Android stable-private-per-SSID still changes on reset/device swap/rotate. Client then appears NEW/Preauthenticated (`session_start=0, session_end=null, state=Preauthenticated, custom=none`) and must re-enter voucher. Acceptable; matches state machine (no active session → login).
* Transparent auto-resume across MAC change is impossible without client secret (cookies fail in CPD; voucher re-entry is the secret).
* Mitigation: allow re-binding with single-session eviction (§8), normalize voucher (uppercase, strip spaces), log `mac/ip/token/client_type` each auth.

## 10. True 6-hour usage accounting (not wall-clock)

Native `session_length` is wall-clock (`session_end = start + timeout`). Pause is external:

* Backend (Postgres/Ubuntu) authoritative: `total_quota=21600s`, `used_secs`, `state NEW/ACTIVE/PAUSED/EXPIRED`, `bound_mac`, `resume_ts`.
* `auth_client` (`custombinauth.sh`): validate, `remaining = total - used`, deny if `≤0` (`exitlevel=1`), else `session_length = ceil(remaining/60)` mins + 10 Mbps rates, `resume_ts=now`, `state=ACTIVE`.
* Any deauth (`client_deauth, idle_deauth, timeout_deauth, ndsctl_deauth, shutdown_deauth` — list `binauth_log.sh:146-157`, demux `195`): `used += now - resume_ts`, `state=PAUSED` (or `EXPIRED` if `remaining≤0`). Explicit PAUSE = `ndsctl deauth` → same path.
* Event-only sync (auth/deauth/pause/resume) via `uclient-fetch`/`wget` from router (has WAN). No per-second writes. Optional infrequent reconciler (e.g. 5 min `ndsctl json` deltas) only for unclean disconnects where `idle_deauth` is delayed — RAM-only on EAP.
* Correct minute-granularity over-grant on deauth rather than trusting `session_end`.

## 11. Status access while paused

Paused = deauthenticated. Deauthed/preauthenticated clients still reach MHD (`status.client` / `:2050`) — captive-portal property. Internet blocked by nftables, portal not.

* Serve status locally by MHD (forked `client_params.sh`). If browser fetched Ubuntu directly, paused clients would need walled-garden exception (`libopennds.sh:3089-3130 nftset`, `1393-1596 nft_set`). Avoid: browser→MHD only; MHD (router, WAN) →Ubuntu server-side.
* Stock Logout `client_params.sh:217` (`GET $url/opennds_deny/`) proves deauthed clients invoke MHD actions. Reuse for PAUSE; RESUME re-enters `/opennds_preauth/`.
* `gatewayfqdn=status.client` resolution via `dnsconfig.sh:96-135 hostconf` (`/$gw_fqdn/$gw_ip` via `uci`, uncommitted). Do not break it.
