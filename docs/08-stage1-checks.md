# Stage 1 checks — evidence log (for ChatGPT)

Commands were run locally in `/home/gib/portal_eap`. No EAP contact.
`theme_voucher.sh` = 325 lines, `-rwxrwxr-x`, `sh -n` → `SYNTAX_OK`.

## 1. Syntax + executable

```text
chmod +x theme_voucher.sh
sh -n theme_voucher.sh → SYNTAX_OK
head -1 → #!/bin/sh
```

`shellcheck` not installed → skipped (recorded, not failed).

## 2. Required symbols

```text
title="theme_voucher"                                  # :29
generate_splash_sequence()                             # :33
voucher_login()                                        # :37
header() / footer() / login_form()                     # :50/:148/:162
thankyou_page() + binauth_custom + encode_custom       # :195/:200/:201
landing_page()                                         # :229
additionalthemevars="voucher"                          # :315
fasvarlist="$fasvarlist $additionalthemevars"          # :317
```

Top-level assignments only (quotas, ndsparamlist, fasvarlist, userinfo) —
same shape as stock `theme_user-email-login-basic.sh:427-484`.
No top-level `encode_custom` / `auth_log` calls (correct: per-submission only).

## 3. Forbidden-pattern audit

* `eval` → only `revalidate` (meta tag) + `non-eval` (comment). No code `eval`.
* Backticks → none.
* Direct `ndsctl` → none in code (2 comment mentions only).
  Auth uses wrappers `encode_custom()` + `auth_log()` from `libopennds.sh`.
* `$(` → only `year=$(date)` (stock-identical footer) + `originurl/gatewayurl`
  url-decodes (stock-identical `landing_page`). No `$(...$voucher...)`.
* Bashisms (`[[`, `function`, `declare`, `local`, `&>`, `==`) → none
  (one false hit: comment word “local OpenNDS”).
* `PORTAL-TEST` → 1 line, header comment only. Zero `if/case` branches on it.
* JS/CPD → no `<script`, `javascript`, `onClick`, `href`, `splash.css`,
  `index.css` link. One `action="http://$gatewayfqdn"` form target (retry submit,
  not a link; JS-free replacement for stock `onClick` button).

## 4. Voucher-exposure audit (`grep -n voucher|custom`)

* Comments/header: flow + privacy notes (expected).
* Code uses:
  * `login_form` input `value="$voucher"` — required re-serve preservation.
  * `thankyou_page` hidden `voucher` + hidden `custom` — required FAS handoff.
  * `binauth_custom="voucher=$voucher"` — plain assignment, no eval.
  * `userinfo` — marker `stage1-test-bypass (no validation)`, NO voucher value.
* Visible-text check: `thankyou`/`landing` templates contain no `$voucher`/`$custom`
  echoes outside `value=`/hidden inputs.

## 5. Mock-source render (stubbed library, `/tmp` only)

Setup: stub `encode_custom` → fixed `custom`, stub `auth_log` → authenticated,
stub `configure_log_location` → `/tmp`, preset `fas/voucher/custom/urls`.

Results:

```text
fasvarlist=[terms landing status continue custom voucher]   # voucher parsed
login_form:    name="fas"×1, name="voucher"×1, /opennds_preauth/×1, CONNECT, WI-FI E-VOUCHER
thankyou_page: name="fas"×1, name="voucher"×1, name="custom"×1, name="landing"×1, VOUCHER RECEIVED
thankyou plaintext PORTAL-TEST hits: 1 (hidden field only)
landing_page:  REQUEST SENT ×1, plaintext PORTAL-TEST hits: 0
landing_exit=0
```

`landing_page` calls `footer` → `exit 0` (stock contract); harness used subshell
so the exit did not kill the test runner. `/tmp` artifacts removed afterward.

## 6. Untouched-files proof

```text
opennds/ mtimes still 2026-09-12 23:44 (authmon/binauth_log/client_params/...
  custombinauth/dnsconfig/download_resources/get_client_interface/libopennds/...)
theme_voucher.sh mtime = build time only (new file)
index.html / index.css / status.html mtimes unchanged
```

No `uci`, `scp`, `ssh`, firewall, or `/etc/config/opennds` commands were run.
