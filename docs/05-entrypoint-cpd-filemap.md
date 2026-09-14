# 12–16. Entrypoint, CPD, file map, new files, layout

## 12. Single entry `10.0.0.1` without breaking LuCI

* `10.0.0.1:80` → uhttpd/LuCI; `10.0.0.1:2050` → MHD. Gateway-IP requests are NOT DNAT'd to MHD, so `10.0.0.1` shows LuCI today.
* Do not set `gatewayport 80` while uhttpd owns it; do not change `gatewayfqdn/statuspath`/firewall/DHCP yet.
* Path: (a) rely on CPD + DHCP option 114 (`dnsconfig.sh:137-183 cpidconf` installs `114,http://$gatewayfqdn` per zone, uncommitted) + DNS hijack; document `http://10.0.0.1:2050` fallback. (b) Later, minimal port-80 handler checking `ndsctl json <remote-ip>` and redirecting unauth → `:2050`/`status.client`, auth → status, preserving `/cgi-bin/luci`. Moving LuCI off 80 risks lockout.
* Audit `users_to_router` (`libopennds.sh:1213-1251`, `pre_setup:1350-1351`, `restart.sh:7-13`) before exposing router services.

## 13. CSS/JS in CPD browsers

`libopennds.sh:2306-2313` warns CPD MAY: close on auth, prohibit `href`, prohibit external files **including `.css`/`.js`**, prohibit JS.

* `index.html:7` / `status.html:7` external `index.css` will fail in many CPD mini-browsers. Inline cleaned `<style>` in ThemeSpec `header()` instead (stock links `$gatewayurl/splash.css` at `theme_click-to-continue-basic.sh:31`, `client_params.sh:157` — still external; inlining safer).
* CSS vars/grid/flex (`index.css:8-18,152-160`) OK in full browsers, but keep no-JS fallback. Render remaining server-side; plain `GET` forms to `/opennds_preauth/` and `$url/opennds_deny/`. `status.html:30-32` countdown and `55` JS-less `type="button"` must become server text + submit forms. Avoid `fetch/XHR`, external fonts, `href` (stock uses button `onClick location.href`, e.g. `theme_click-to-continue-basic.sh:186`).

## 14. Which file to extend/replace

* Login ThemeSpec → **new** file modelled on `theme_user-email-login-basic.sh` (custom input + `binauth_custom` + `encode_custom` at `141-142`). Do not edit `libopennds.sh`. Enable via `login_option_enabled=3` + `themespec_path`.
* Status → **fork** `client_params.sh` (`statuspath`). Only MHD endpoint for `status/err511` (`317-354`).
* Validation + accounting → **`custombinauth.sh`** (documented point: `binauth_log.sh:277-298`, `custombinauth.sh:9-10`). Leave `binauth_log.sh` untouched unless proven.
* Pause/resume → forms in forked status reusing `opennds_deny` (pause) + `/opennds_preauth/` (resume); backend infers from BinAuth callbacks. No new MHD endpoint unless tests demand.
* Reference: `theme_*-custom-placeholders.sh` show `download_image/data_files`, `custom_inputs/passthrough` (`121,189,282-284`), `ndscustomparams/images/files` (`495-499`, `512-516`). `authmon.sh`, `post-request.php`, `dnsconfig.sh`, `get_client_interface.sh`, `download_resources.sh`, `restart.sh` need no changes for local-BinAuth.

## 15. Minimum new files

On EAP, **2 new + 1 modified**:

1. `theme_voucher.sh` (login + thankyou + landing, inline CSS, no ToS).
2. `client_params_voucher.sh` (ACTIVE/PAUSED/EXPIRED, remaining, voucher, PAUSE/RESUME, `custom` parsing).
3. `custombinauth.sh` (stub→real: validation + accounting + EAP→Ubuntu client + RAM cache).

Off-EAP: minimal Ubuntu API + Postgres (`vouchers, sessions/events`). No RADIUS/Mendyfi/Omada/Vercel/Supabase — local path sufficient.

## 16. Proposed layout

```text
~/portal_eap/                  # repo (dev)
  index.html / index.css / status.html   # design source only
  opennds/                     # pristine EAP copies
  themes/
    theme_voucher.sh
    client_params_voucher.sh
    custombinauth.sh
  backend/                     # Ubuntu API + SQL (off-EAP)

/usr/lib/opennds/              # EAP (deploy)
  libopennds.sh                # untouched
  binauth_log.sh               # untouched
  theme_voucher.sh             # themespec_path → here
  client_params_voucher.sh     # statuspath → here
  custombinauth.sh             # extension
/tmp/ndslog/ /tmp/ndscids/     # RAM only
```

Later config: `login_option_enabled=3`, `themespec_path`, `statuspath`, strong `faskey`, `sessiontimeout`/rates defaults, `log_mountpoint=/tmp`.
