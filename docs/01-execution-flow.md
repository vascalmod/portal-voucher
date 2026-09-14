# 1. Exact OpenNDS execution flow

## 1a. Intercept → MHD preauth

Unauthenticated clients are redirected by nftables (`libopennds.sh:1288-1356` `pre_setup()`) to MHD on `:2050`.

MHD invokes `libopennds.sh` as CGI-like handler. Dispatch:

* `libopennds.sh:2174-2178`: if `$1` starts with `%3ffas%3d` (url-encoded `?fas=`) → splash-sequence mode.

Defaults (`libopennds.sh:2189-2244`):

* `custom=""`, `session_length="0"`, `upload_rate/download_rate/upload_quota/download_quota="0"`, `quotas=...` at `2228`.
* `ndsparamlist="hid clientip clientmac client_type cpi_query gatewayname gatewayurl version gatewayaddress gatewaymac originurl clientif"` at `2234`.
* `fasvarlist="terms landing status continue custom"` at `2239`.
* `configure_log_location` + `. $mountpoint/ndscids/ndsinfo` at `2243-2244`.

Then (`2252-2297`):

```sh
get_theme_environment $1 $2 $3 $4   # 2252
config_input_fields "input"         # 2260
fasvarlist="$fasvarlist $inputnames" # 2263
get_arguments                       # 2265
config_input_fields "hidden"        # 2267
header                              # 2280
terms? display_terms                 # 2283-2285
landing? landing_page               # 2287-2290
check_authenticated                 # 2294
generate_splash_sequence            # 2297
```

## 1b. `get_theme_environment()` — `libopennds.sh:361-491`

* `query_enc=$1`, `user_agent_enc=$2`, `mode=$3`, themespec `$4`.
* `367-396`: url-decode `%xx`, require `?fas=` prefix, split trailing `, var=val` pairs into `$fasvars` with `htmlentityencode`.
* `404-417`: `mode 0/1 → theme_click-to-continue-basic.sh`, `2 → theme_user-email-login-basic.sh`, `3 → $4`, else error.
* `427`: `. $themespecpath` — defines `generate_splash_sequence()`, `header()`, `footer()`.
* `443-489`: fragment b64-decode via `ndsctl b64decode` (`464-466`), `parse_variables`, cache in `$mountpoint/ndscids/$cid` (`482-489`, `cid` at `401`).

## 1c. ThemeSpec dialogue loop

Pattern `theme_user-email-login-basic.sh:65-105`:

```sh
generate_splash_sequence() -> name_email_login()
  if username+emailaddress present -> thankyou_page()
  else login_form()  # <form action="/opennds_preauth/" method="get">
```

`login_form()` at `84-105`:

```html
<form action="/opennds_preauth/" method="get">
  <input type="hidden" name="fas" value="$fas">
  <input type="text" name="username" ...>
  <input type="email" name="emailaddress" ...>
```

Submit re-enters `libopennds.sh` with new `fasvars`. `get_arguments()` (`493-515`) + `parse_variables()` (`517-536`) extract them.

`thankyou_page()` at `107-166`:

* `141: binauth_custom="username=$username emailaddress=$emailaddress"`
* `142: encode_custom`
* `144-148`: wrap `$custom` in `$customhtml` hidden input.
* `152-160`: form with `fas, username, emailaddress, custom, landing=yes` → `/opennds_preauth/`.

## 1d. `landing_page()` → `auth_log()` → `ndsctl auth` → BinAuth

`libopennds.sh:2287-2290` calls ThemeSpec `landing_page()` when `landing=yes`.

Example `theme_user-email-login-basic.sh:168-180`:

```sh
. $mountpoint/ndscids/ndsinfo  # 173
userinfo=...                   # 176
auth_log                       # 179
```

`auth_log()` at `718-731`:

```sh
rhid=$(printf "$hid$key" | sha256sum | awk ...)  # 721
ndsctlcmd="auth $rhid $quotas $custom"           # 722
do_ndsctl                                        # 724
```

`key` from `get_key_from_config()` (`1111-1120`, `faskey` option, empty default).

`do_ndsctl()` at `304-359`: `eval ndsctl "$ndsctlcmd"` with 16× retry, busy/authenticated/deauthenticated/failed detection.

Daemon then calls `binauth_log.sh auth_client ...`.

## 1e. `binauth_log.sh:141-309`

* `158: action=$1`.
* `160-176` `auth_client` args: `$2 mac, $3 originurl/redir, $4 useragent, $5 ip, $6 token, $7 custom(b64)`.
* `179-200` other methods: `$2 mac, $3 bytes_in, $4 bytes_out, $5 sess_start, $6 sess_end, $7 token, $8 custom`.
* `231-235`: `grep -r "$2" "$mountpoint/ndscids"` → `. $mountpoint/ndscids/$cidfile`.
* `245`: `get_client_zone`.
* `251-255`: append to `$logdir/binauthlog.log` via `libopennds.sh "write_log"` (`125-127`).
* `260-275`: maintain `$logdir/authlog.log` as `b64mac=session_end`, `sed -i` delete old, `date_inhibit` set.
* `280-285`: defaults `session_length/upload_rate/download_rate/upload_quota/download_quota=0, exitlevel=0`.
* `287-291`: `custom=$7` (auth) else `$8`.
* `294-298`: `. /usr/lib/opennds/custombinauth.sh`.
* `302`: `echo "$session_length $upload_rate ..."`.
* `309`: `exit $exitlevel` (0=allow, 1=deny, only effective for `auth_client`).

`custombinauth.sh:1-13` is the empty stub documented to override those 6 variables.
CPD warnings at `libopennds.sh:2306-2313` apply to all HTML emitted here.
