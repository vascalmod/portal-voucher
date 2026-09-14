# 2–4. ThemeSpec variables, BinAuth args, voucher passing

## 2. Exact variables available to ThemeSpec

From `libopennds.sh:2234,2239` + theme footers:

NDS params (`ndsparamlist`):

```text
hid, clientip, clientmac, client_type, cpi_query, gatewayname, gatewayurl,
version, gatewayaddress, gatewaymac, originurl, clientif
```

plus theme-appended `ndscustomparams/images/files`.

FAS vars (`fasvarlist`):

```text
terms, landing, status, continue, custom
```

plus `additionalthemevars` (e.g. `username emailaddress` in `theme_user-email-login-basic.sh:462-464`; empty in `theme_click-to-continue-basic.sh:449`).

Also in scope after `get_arguments` + `get_client_zone` (`689-716`):

* `fas` (stripped to value only, `510`), `user_agent` (decoded, `499`), `client_zone`, `quotas`, `userinfo`, `title`, `imagepath`, `mountpoint/logdir/logname`, `custom_inputs/custom_passthrough/inputnames` (from `config_input_fields`, `879-973`), `custom` (from `encode_custom`), `hid/key/rhid` at auth time.

CID-file vars documented `binauth_log.sh:203-228`: `clientip, clientmac, gatewayname, version, client_type, hid, gatewayaddress, gatewaymac, originurl, clientif` + custom placeholders (`input, logo_message, banner*_message, logo_png, banner*_jpg, advert1_htm` example).

## 3. Exact variables/args to `binauth_log.sh` and `custombinauth.sh`

Positional args — see `01-execution-flow.md §1e`:

* `auth_client`: `$2 mac, $3 originurl/redir, $4 useragent, $5 ip, $6 token, $7 custom(b64)` (`binauth_log.sh:160-168`).
* Others: `$2 mac, $3 bytes_in, $4 bytes_out, $5 sess_start, $6 sess_end, $7 token, $8 custom` (`179-193`).

`custombinauth.sh` is sourced at `binauth_log.sh:294-298`, inherits all shell state:

`action, loginfo, mountpoint/logdir/fulllog/authlog, client_zone, session_end, custom, session_length/upload_rate/download_rate/upload_quota/download_quota/exitlevel`, plus sourced CID vars (`client_type, gatewayname, version, originurl...`) or fallback `clientmac=$2` (`240-241`), plus `$2-$8` still in scope.

Constraint `binauth_log.sh:170-174`: inside BinAuth only `ndsctl b64encode/b64decode` are usable; other `ndsctl` verbs are locked. Decode via:

```sh
customdata=$(ndsctl b64decode "$custom")
```

Deferred auth/deauth must use `libopennds.sh daemon_auth/daemon_deauth` pattern (`2819-2889`) or a separate helper process, not direct `ndsctl` in BinAuth.

## 4. Voucher passing: form → ThemeSpec → `encode_custom()` → BinAuth

Proven pattern `theme_user-email-login-basic.sh:141-148`:

1. Extend `fasvarlist`: `additionalthemevars="voucher"` (analogy to `462-464`).
2. Login form: `<form action="/opennds_preauth/" method="get">` + `<input type="hidden" name="fas" value="$fas">` + `<input name="voucher" ...>` (current `index.html:22-39` lacks action/fas — must be adapted).
3. Resubmit → `get_theme_environment:379-393` appends `voucher=...` to `$fasvars` → `get_arguments` + `parse_variables:517-536` sets `$voucher` (html-entity-encoded).
4. `thankyou_page`: `binauth_custom="voucher=$voucher"` (optionally `+ op=login|resume`, `mac=$clientmac` as metadata) → `encode_custom()` (`libopennds.sh:66-75`):

   ```sh
   ndsctlcmd="b64encode \"$binauth_custom\""
   do_ndsctl; custom=$ndsctlout
   ```

5. Emit `$custom` as hidden `custom` field → `landing_page` → `auth_log:722` → `ndsctl auth $rhid $quotas $custom`.
6. `binauth_log.sh:287` receives it as `$7`; `custombinauth.sh` does `ndsctl b64decode` to recover `voucher=...`.

Multi-page preservation uses `$custom_passthrough` hidden inputs (`libopennds.sh:957-969`, used in `theme_click-to-continue-custom-placeholders.sh:189,282`).

Note: `encode_custom` is NOT automatic. `libopennds.sh:2197-2200` and theme footers (`459-462`) leave it commented; ThemeSpec must call it explicitly after setting `binauth_custom`.
Hyphen in `ABCD-1234` is not in the entity-encode list (`640-662`: `"` `;` `>` `<` `%` `'` `` ` `` `?` `$` `/` `\`), so it survives, but still validate with allowlist before shell/API use (see `06-security-constraints-bugs.md`).
