# Stage 1 — Voucher login ThemeSpec (plan, not implemented)

> Send this file to ChatGPT to confirm the plan before any EAP change.
> No code is deployed by this document. Stage 1 = UI + data flow only.

## 0. Context

* Device: TP-Link EAP225-Outdoor V3
* OS: OpenWrt 25.12.x (`apk`, not `opkg`; no package install needed)
* Captive portal: openNDS 10.3.1-r3, MHD `10.0.0.1:2050`, LuCI `:80`
* LAN gateway: `10.0.0.1/24`, WAN/upstream: `192.168.100.1`
* `gatewayfqdn=status.client`, `statuspath` default (`client_params.sh`)
* Authoritative implementation: `~/portal_eap/opennds/` (copies from EAP, do not assume upstream)
* Approved UI (do not redesign): `index.html`, `index.css`, `status.html`
* Prior analysis: `docs/` (static inspection report)

## 1. Stage 1 goal / non-goals

Goal — smallest first step:

```text
EXISTING APPROVED UI + ONE NEW THEMESPEC = WORKING LOCAL VOUCHER LOGIN PAGE
real Wi-Fi client → OpenNDS → local ThemeSpec → WI-FI E-VOUCHER design
```

Login shows: `WI-FI E-VOUCHER`, voucher input (`ABCD-1234` placeholder),
`CONNECT`, `₱5 / 6 HOURS / 10 Mbps`, no Terms & Conditions.

Stage 1 implements only:

* Port login UI into local ThemeSpec
* Accept `voucher` through `/opennds_preauth/` correctly
* Carry it via `binauth_custom` → `encode_custom()` → `custom` → BinAuth
* Test hook voucher `PORTAL-TEST` verifies flow (not hard-coded as valid)

Explicitly NOT in Stage 1:

* PostgreSQL / API, real validation, 6-hour accounting, pause/resume,
  custom status page, port-80 replacement, LuCI/firewall/DHCP changes,
  edits to `libopennds.sh` / `binauth_log.sh` / default scripts,
  roulette / points.

## 2. Architecture grounding (verify against local files)

* `login_option_enabled=3` loads `themespec_path` (`libopennds.sh:404-411`;
  `3 → $4`, missing file → `Bad or Missing ThemeSpec:419-424`).
* MHD preauth dispatch: `libopennds.sh:2174-2178` (`%3ffas%3d`), defaults
  `custom=""`, `session_length="0"`, rates/quotas `0` (`2189-2228`),
  `ndsparamlist="hid clientip clientmac client_type cpi_query gatewayname gatewayurl version gatewayaddress gatewaymac originurl clientif"` (`2234`),
  base `fasvarlist="terms landing status continue custom"` (`2239`).
* Sequence: `get_theme_environment $1 $2 $3 $4` (`2252`) →
  `config_input_fields "input"` (`2260`) → append `inputnames` (`2263`) →
  `get_arguments` (`2265`) → `config_input_fields "hidden"` (`2267`) →
  `header` (`2280`) → `terms?` (`2283`) → `landing? landing_page` (`2287-2290`) →
  `check_authenticated` (`2294`) → `generate_splash_sequence` (`2297`).
* `get_theme_environment` (`361-491`): url-decode, require `?fas=` (`373`),
  split `, var=val` into `$fasvars` with `htmlentityencode` (`379-393`),
  `. $themespecpath` (`427`), fragment `ndsctl b64decode` (`464-466`),
  `parse_variables` with `$ndsparamlist` (`473-475`), cache `$mountpoint/ndscids/$cid` (`482-489`).
* `get_arguments` + `parse_variables` (`493-536`): decode `user_agent` (`499`),
  parse `$fasvars` with `$fasvarlist` (`502-506`), sanitize each value via
  `htmlentityencode` (`524-526`), assign via `eval $var="..."` (`532`),
  strip `fas=` prefix (`510`), `get_client_zone` (`513`).
* Stock form pattern (`theme_user-email-login-custom-placeholders.sh:125-137`):
  `<form action="/opennds_preauth/" method="get">` + hidden `fas` + named inputs.
* Stock encode pattern (`188-207`): `binauth_custom="..."` (`188`) →
  `encode_custom` (`189`) → `$customhtml` hidden (`191-195`) → second form with
  `fas` + original fields + `custom` + `landing=yes` (`199-207`).
* `encode_custom` (`libopennds.sh:66-75`): `ndsctl b64encode "$binauth_custom"` →
  `custom=$ndsctlout`; NOT automatic (core `2197-2200` commented; ThemeSpec must call it).
* `landing_page` stock (`216-227`): url-decode urls, `. $mountpoint/ndscids/ndsinfo`,
  extend `userinfo`, call `auth_log`.
* `auth_log` (`718-731`): `rhid=sha256(hid+key)` (`721`, `key` = `faskey` via
  `get_key_from_config:1111-1120`) → `ndsctl auth $rhid $quotas $custom` (`722`).
* `binauth_log.sh:158-309`: `auth_client` args
  `$2 mac, $3 originurl, $4 UA, $5 ip, $6 token, $7 custom(b64)` (`160-168`);
  others `$2 mac, $3 in, $4 out, $5 start, $6 end, $7 token, $8 custom` (`179-193`);
  CID lookup `grep -r "$2" ndscids` + source (`231-235`); logs to
  `$logdir/binauthlog.log` / `authlog.log` (`251-275`); defaults
  `session_length/rates/quotas=0, exitlevel=0` (`280-285`); `custom=$7|$8`
  (`287-291`); source `custombinauth.sh` (`294-298`); `echo` quotas (`302`);
  `exit $exitlevel` (`309`). Inside BinAuth only `b64encode/b64decode` allowed
  (`170-174`). Current `custombinauth.sh:1-13` = stub (allows all).
* CPD limits (`libopennds.sh:2306-2313`): may close on auth, block `href`,
  block external `.css`/`.js`, block JS. Therefore inline CSS, no JS, plain GET forms.
* Current UI gaps: `index.html:22-39` lacks `action/method/fas`;
  `index.html:7` / `status.html:7` external CSS will fail in CPD;
  `index.css:1` fence invalid; `status.html:55` PAUSE inert.

## 3. Proposed new file only

Create (build step, not yet done):

```text
~/portal_eap/theme_voucher.sh
```

Spec:

1. `#!/bin/sh` (busybox ash compatible, no bashisms).
2. Uses library environment only; does not copy/modify `libopennds.sh`.
3. Footer config:
   `session_length="0"`, rates/quotas `0`, `quotas=...`,
   `ndscustomparams/images/files=""`, extend `ndsparamlist`,
   `additionalthemevars="voucher"`, `fasvarlist="$fasvarlist $additionalthemevars"`,
   `userinfo="theme_voucher"`.
4. Defines `generate_splash_sequence()` → `voucher_login()`.
5. Defines `header()` (inline `<style>`, no `splash.css` link),
   `footer()` (close + `exit 0`), `login_form()`, `thankyou_page()`, `landing_page()`.
6. Renders WI-FI E-VOUCHER brand + plan row from `index.html`/`index.css`
   (base, container, card, brand, voucher-form, plan, mobile; strip fence).
7. `login_form`: `action="/opennds_preauth/" method="get"`, hidden `fas`,
   `name="voucher" value="$voucher" maxlength="20" autocomplete="off"`,
   `CONNECT` submit. Empty `$voucher` re-serves login. No ToS.
8. `thankyou_page`: echo voucher (already entity-encoded), then
   `binauth_custom="voucher=$voucher"` → `encode_custom` →
   `$customhtml` + `fas/voucher/custom/landing=yes` Continue form.
9. `landing_page`: decode urls, source `ndsinfo`, `userinfo` + voucher,
   `auth_log`, minimal success/fail output showing voucher/custom for flow check.
10. No JS, no CDN, no `href` navigation, no `eval` on voucher,
    no direct `ndsctl`, no hard-coded `PORTAL-TEST`.

## 4. Data flow to confirm

```text
form [voucher] + hidden fas
→ GET /opennds_preauth/?fas=<b64...>&voucher=PORTAL-TEST
→ get_theme_environment fasvars → get_arguments/parse_variables → $voucher
→ thankyou_page: binauth_custom="voucher=PORTAL-TEST" → encode_custom → $custom
→ hidden custom + landing=yes → landing_page → auth_log → ndsctl auth $rhid $quotas $custom
→ BinAuth auth_client $7=$custom → custombinauth ndsctl b64decode → voucher=PORTAL-TEST
→ ndsctl json custom + binauthlog.log record
```

## 5. Security contract

* Trust core `htmlentityencode` (`libopennds.sh:640-662`: `" ; > < % ' ` ? $ / \` + `parse_variables:524-532`).
* ThemeSpec: never `eval`/backtick/`$()` voucher; only `binauth_custom="voucher=$voucher"`
  (plain assignment) + quoted `encode_custom` + HTML reflect of encoded value.
* Future stage adds allowlist `^[A-Z0-9-]{4,20}$` + uppercase/trim before API/SQL;
  Stage 1 passes through only.
* `custombinauth.sh` runs as root — no change in Stage 1; API key handling is Stage 2.
* Set strong `faskey` before production (`rhid` predictable if empty).

> Auth note: Stage 1 `landing_page` calls `auth_log` to prove flow.
> Existing stub (`exitlevel=0`) will allow the test attempt. This is retained
> default behavior for flow verification, NOT new validation. Real deny
> (`exitlevel=1`) arrives with Stage 2 voucher DB.

## 6. Local checks (no EAP)

* `sh -n theme_voucher.sh`
* `grep -n 'eval\|binauth_custom\|encode_custom\|generate_splash_sequence\|additionalthemevars\|voucher' theme_voucher.sh`
* Confirm: defines required functions; `additionalthemevars` includes `voucher`;
  single `encode_custom` after assignment; no unquoted `$voucher` in command position.
* Optional mock-source render with stubbed `encode_custom/header/footer/auth_log`.

## 7. EAP deploy (manual, do not auto-run)

```sh
scp ~/portal_eap/theme_voucher.sh root@10.0.0.1:/usr/lib/opennds/theme_voucher.sh
ssh root@10.0.0.1 'chmod +x /usr/lib/opennds/theme_voucher.sh && sh -n /usr/lib/opennds/theme_voucher.sh && ls -l /usr/lib/opennds/theme_voucher.sh'
ssh root@10.0.0.1 'uci show opennds | grep -E "login_option_enabled|themespec_path|statuspath|faskey"; cp /etc/config/opennds /tmp/opennds.bak.stage1'
ssh root@10.0.0.1 'uci set opennds.@opennds[0].login_option_enabled="3" && uci set opennds.@opennds[0].themespec_path="/usr/lib/opennds/theme_voucher.sh" && uci show opennds | grep -E "login_option_enabled|themespec_path"'
ssh root@10.0.0.1 '/etc/init.d/opennds reload; sleep 3; logread -e opennds | tail -n 50; ndsctl status'
```

Leave `statuspath`, port 80, LuCI, firewall unchanged.

## 8. Rollback

```sh
ssh root@10.0.0.1 'cp /tmp/opennds.bak.stage1 /etc/config/opennds && uci show opennds | grep -E "login_option_enabled|themespec_path" && /etc/init.d/opennds reload'
ssh root@10.0.0.1 'rm /usr/lib/opennds/theme_voucher.sh; /etc/init.d/opennds reload; ndsctl status'
```

## 9. EAP test (client 10.0.0.200, voucher PORTAL-TEST)

1. Associate client, confirm DHCP `10.0.0.200`; `ndsctl json 10.0.0.200` = `Preauthenticated`.
2. Open `http://10.0.0.1:2050/` (or CPD); confirm WI-FI E-VOUCHER renders, no ToS.
3. Enter `PORTAL-TEST` → submit → thankyou shows voucher → Continue → landing.
4. On EAP: `logread | grep -i opennds`, `tail /tmp/ndslog/binauthlog.log`,
   `ndsctl json 10.0.0.200`, `ndsctl b64decode <custom>` contains `voucher=PORTAL-TEST`.
5. Confirm `statuspath`, `:80`, firewall untouched. Stop; save JSON + logs for Stage 2.

## 10. Confirmation checklist for ChatGPT

* [ ] FAS mechanism matches local `libopennds.sh` (not generic docs)?
* [ ] `additionalthemevars="voucher"` sufficient for `$voucher`?
* [ ] Two-step `login → thankyou(encode) → landing(auth)` required?
* [ ] Hidden `fas` / `custom` / `landing` fields complete?
* [ ] CPD-safe (inline CSS, no JS/CDN/href)?
* [ ] No unsafe shell use of voucher?
* [ ] Deploy/rollback safe, no port/firewall/LuCI change?
* [ ] Test proves `custom` reaches BinAuth without claiming real validation?
* [ ] No Stage 2 scope leaked?
