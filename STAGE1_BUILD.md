# Stage 1 Build — what was made (send to ChatGPT)

> Stage 1 = login UI + FAS data flow only. No validation, no DB, no pause/resume.
> Companion plan: `STAGE1_PLAN_README.md`. Prior analysis: `docs/`.
> EAP untouched by builder — deploy/test below are MANUAL steps for you to run.

## 1. Files created

* `~/portal_eap/theme_voucher.sh` — 325 lines, executable, `sh -n` clean.
  Self-contained OpenNDS ThemeSpec. Only new file for Stage 1.

## 2. Files modified

* NONE. Verified:
  * `opennds/*` mtimes unchanged (still `2026-09-12 23:44`).
  * `index.html`, `index.css`, `status.html` untouched.
  * No `/etc/config/opennds` change, no EAP SSH/SCP executed.

## 3. Adjustments compliance (your 7 rules)

1. **No raw voucher/custom in browser except protocol-necessary.**
   Visible pages (`login` / `VOUCHER RECEIVED` / `REQUEST SENT|FAILED`) render
   NO voucher/custom text. Plaintext voucher exists ONLY in:
   (a) `login_form` input `value="$voucher"` (re-serve preservation, entity-encoded by core),
   (b) hidden `fas` / `voucher` / `custom` / `landing` fields thankyou→landing (FAS-required).
   `userinfo` = marker only, no voucher value. Mock-render proof:
   `landing` = 0 plaintext hits; `thankyou` = 1 hit (hidden field only).
2. **PORTAL-TEST = temporary bypass, not validation.**
   Header banner `theme_voucher.sh:4-14` + `userinfo="..., stage1-test-bypass (no validation)"`.
   No `if voucher == PORTAL-TEST` logic anywhere (single comment mention only).
   Any non-empty voucher takes the same test path. Any allow = existing stub default.
3. **No existing OpenNDS files modified.** Only `theme_voucher.sh` created.
4. **No config auto-modified.** Only manual `uci set` commands documented below.
5. **Untouched:** port 80, LuCI, firewall, DHCP, statuspath, PostgreSQL, pause/resume.
6. **Local checks run BEFORE deploy docs** — see §6 (all passed).
7. **Stops here** — §8 lists explicit out-of-scope.

## 4. ThemeSpec contract (how it fits real 10.3.1 code)

* `#!/bin/sh`, `title="theme_voucher"`.
* `additionalthemevars="voucher"` → `fasvarlist` extension, so
  `libopennds.sh:get_arguments/parse_variables` populates `$voucher`
  (base list `terms landing status continue custom` + `voucher`).
* `generate_splash_sequence()` → `voucher_login()`:
  non-empty `$voucher` → `thankyou_page`, else `login_form`
  (mirrors stock `name_email_login` presence gate; NOT authorization).
* `login_form`: `action="/opennds_preauth/" method="get"` + hidden `fas` +
  `name="voucher" maxlength="20"` + `CONNECT` + plan row `₱5/6 HOURS/10 Mbps`.
* `thankyou_page`: `binauth_custom="voucher=$voucher"` (plain assignment, no eval)
  → `encode_custom()` (quoted `ndsctl b64encode`) → hidden `custom` +
  `fas/voucher/landing=yes` Continue form. No visible voucher echo.
* `landing_page`: url-decode urls, `configure_log_location`,
  `. $mountpoint/ndscids/ndsinfo`, marker-only `userinfo`, `auth_log`
  (`auth $rhid $quotas $custom`), generic success/fail (JS-free Continue forms).
* Footer config: `session_length/rates/quotas = 0` (defaults; Stage 2 sets real),
  empty `ndscustomparams/images/files`, no top-level `encode_custom`,
  no `download_*`, no ToS (`read_terms/display_terms` omitted by design).
* CPD-safe: inline `<style>` from `index.css` (fence stripped, login subset +
  mobile query), no JS/`onClick`/`href`/CDN/`splash.css`/`index.css` link.

## 5. Exact data flow (for ChatGPT to confirm)

```text
form [voucher] + hidden fas
→ GET /opennds_preauth/?fas=<b64...>&voucher=PORTAL-TEST
→ get_theme_environment fasvars (htmlentityencode)
→ get_arguments/parse_variables → $voucher (entity-encoded)
→ thankyou_page: binauth_custom="voucher=PORTAL-TEST" → encode_custom → $custom
→ hidden custom + landing=yes → landing_page → auth_log
→ ndsctl auth $rhid $quotas $custom
→ binauth_log.sh auth_client $7=$custom → custombinauth ndsctl b64decode
→ server-side proof: binauthlog.log + ndsctl json custom
```

## 6. Checks actually run (evidence in `docs/08-stage1-checks.md`)

* `sh -n` → `SYNTAX_OK`; `chmod +x` done locally only.
* `shellcheck` absent → skipped, recorded.
* Required symbols `grep` → all present.
* `eval`/backtick/`ndsctl`-direct audit → clean
  (`eval` hits = `revalidate` + comment; `ndsctl` hits = comments only).
* `$(` audit → only `year=$(date)` + url-decodes (stock-identical, no voucher inside).
* `PORTAL-TEST` → 1 comment mention, zero logic branches.
* Mock-source render with stubbed `encode_custom/auth_log/configure_log_location`:
  `fasvarlist=[... voucher]`; login has fas/voucher/preauth/CONNECT;
  thankyou has fas/voucher/custom/landing hiddens; landing `REQUEST SENT`, 0 leaks.
* `opennds/` mtimes unchanged.

## 7. Manual EAP deployment (NOT executed — run by you)

```sh
scp ~/portal_eap/theme_voucher.sh root@10.0.0.1:/usr/lib/opennds/theme_voucher.sh
ssh root@10.0.0.1 'chmod +x /usr/lib/opennds/theme_voucher.sh && sh -n /usr/lib/opennds/theme_voucher.sh && ls -l /usr/lib/opennds/theme_voucher.sh'
ssh root@10.0.0.1 'uci show opennds | grep -E "login_option_enabled|themespec_path|statuspath|faskey"; cp /etc/config/opennds /tmp/opennds.bak.stage1'
ssh root@10.0.0.1 'uci set opennds.@opennds[0].login_option_enabled="3" && uci set opennds.@opennds[0].themespec_path="/usr/lib/opennds/theme_voucher.sh" && uci show opennds | grep -E "login_option_enabled|themespec_path"'
ssh root@10.0.0.1 '/etc/init.d/opennds reload; sleep 3; logread -e opennds | tail -n 50; ndsctl status'
```

Rollback:

```sh
ssh root@10.0.0.1 'cp /tmp/opennds.bak.stage1 /etc/config/opennds && uci show opennds | grep -E "login_option_enabled|themespec_path" && /etc/init.d/opennds reload'
ssh root@10.0.0.1 'rm /usr/lib/opennds/theme_voucher.sh; /etc/init.d/opennds reload; ndsctl status'
```

Test (client `10.0.0.200`, voucher `PORTAL-TEST`):

1. DHCP `10.0.0.200`; `ndsctl json 10.0.0.200` = `Preauthenticated`.
2. `http://10.0.0.1:2050/` → WI-FI E-VOUCHER, no ToS.
3. `PORTAL-TEST` → CONNECT → `VOUCHER RECEIVED` → Continue → `REQUEST SENT`.
4. EAP: `logread | grep -i opennds`, `tail /tmp/ndslog/binauthlog.log`,
   `ndsctl json 10.0.0.200`, `ndsctl b64decode <custom>` == `voucher=PORTAL-TEST`.
5. Confirm `statuspath`, `:80`, firewall unchanged.

## 8. Full `theme_voucher.sh` (verbatim, 325 lines)

```sh
#!/bin/sh
# theme_voucher.sh — Stage 1 local OpenNDS ThemeSpec (voucher login UI only)
#
# STAGE 1 TEST BYPASS — NOT VALIDATION.
# - This ThemeSpec only proves data flow:
#   form -> FAS -> $voucher -> binauth_custom -> encode_custom -> custom -> BinAuth.
# - "PORTAL-TEST" is a temporary manual data-flow test vector only.
#   It is NOT allowlisted here, NOT hard-coded as valid, and MUST NOT be
#   treated as authorization. Any non-empty voucher reaches the same test path.
# - Real voucher validation / deny (exitlevel=1), 6-hour accounting,
#   pause/resume, status page and backend are Stage 2+ (custombinauth.sh + DB).
# - The current stock custombinauth.sh stub returns exitlevel=0 (allow by
#   default). Any Stage 1 auth success therefore reflects the existing default,
#   not a validation decision by this file.
#
# Privacy (per task adjustment 1):
# - The raw voucher / custom values are NEVER rendered as visible page text.
# - They appear ONLY where the FAS protocol requires them:
#   (a) login input value="$voucher" (preserved re-serve, entity-encoded by core),
#   (b) hidden fas / voucher / custom fields between thankyou -> landing.
# - userinfo intentionally does NOT contain the voucher value (marker only).
#
# Constraints honoured:
# - Does NOT modify libopennds.sh, binauth_log.sh, client_params.sh or config.
# - No port 80 / LuCI / firewall / DHCP / statuspath changes.
# - Inline CSS only (CPD-safe). No JavaScript, no external files, no CDN.
# - Visuals adapted from ~/portal_eap/index.html + index.css (fence line removed).

title="theme_voucher"

# functions:

generate_splash_sequence() {
	voucher_login
}

voucher_login() {
	# Stage 1 gate: non-empty voucher proceeds to thankyou (encode) path,
	# mirroring stock "both fields present -> thankyou_page" logic.
	# This is a presence gate for flow testing, NOT voucher authorization.
	if [ ! -z "$voucher" ]; then
		thankyou_page
		footer
	fi

	login_form
	footer
}

header() {
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<title>WI-FI E-VOUCHER</title>
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		:root {
			--background: #f4f6f8;
			--card: #ffffff;
			--text: #17202a;
			--muted: #7b8794;
			--line: #e5e9ed;
			--primary: #1677ff;
			--primary-dark: #0f62d6;
		}
		body {
			min-height: 100vh;
			font-family: Arial, Helvetica, sans-serif;
			background: var(--background);
			color: var(--text);
			display: flex;
			align-items: center;
			justify-content: center;
			padding: 20px;
		}
		.container { width: 100%; max-width: 420px; }
		.card {
			background: var(--card);
			border: 1px solid var(--line);
			border-radius: 18px;
			padding: 30px 24px;
			box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06);
		}
		.brand { text-align: center; margin-bottom: 30px; }
		.brand-icon {
			width: 58px; height: 58px;
			margin: 0 auto 16px;
			border-radius: 16px;
			background: var(--primary);
			color: #ffffff;
			display: flex;
			align-items: center;
			justify-content: center;
			font-size: 13px;
			font-weight: bold;
		}
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.brand p { margin-top: 7px; font-size: 12px; color: var(--muted); letter-spacing: 1px; }
		.voucher-form { display: flex; flex-direction: column; }
		.voucher-form label { font-size: 13px; font-weight: 600; margin-bottom: 8px; }
		.voucher-form input {
			width: 100%; height: 50px;
			padding: 0 15px;
			border: 1px solid var(--line);
			border-radius: 10px;
			outline: none;
			font-size: 15px;
		}
		.voucher-form input:focus { border-color: var(--primary); }
		.voucher-form input::placeholder { color: #a6afb8; }
		.voucher-form button {
			width: 100%; height: 50px;
			margin-top: 14px;
			border: 0; border-radius: 10px;
			background: var(--primary); color: #ffffff;
			font-size: 14px; font-weight: bold;
			cursor: pointer;
		}
		.plan {
			display: grid;
			grid-template-columns: repeat(3, 1fr);
			margin-top: 24px;
			border-top: 1px solid var(--line);
			padding-top: 20px;
		}
		.plan-item { text-align: center; border-right: 1px solid var(--line); }
		.plan-item:last-child { border-right: 0; }
		.plan-item strong { display: block; font-size: 14px; }
		.plan-item span { display: block; margin-top: 5px; font-size: 10px; color: var(--muted); letter-spacing: 0.5px; }
		.note { margin-top: 16px; text-align: center; font-size: 11px; color: var(--muted); line-height: 1.5; }
		@media (max-width: 400px) {
			body { padding: 12px; }
			.card { padding: 25px 18px; border-radius: 15px; }
			.plan-item strong { font-size: 12px; }
		}
		</style>
		</head>
		<body>
		<main class=\"container\">
	"
}

footer() {
	year=$(date +'%Y')
	echo "
		<div class=\"note\">
			Stage 1 test page &middot; $year
		</div>
		</main>
		</body>
		</html>
	"

	exit 0
}

login_form() {
	# $voucher here is entity-encoded by libopennds parse_variables; safe to
	# reflect inside the quoted value attribute for re-serve preservation.
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>CONNECT TO INTERNET</p>
			</div>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<label for=\"voucher\">Voucher Code</label>
				<input
					type=\"text\"
					id=\"voucher\"
					name=\"voucher\"
					placeholder=\"ABCD-1234\"
					autocomplete=\"off\"
					maxlength=\"20\"
					value=\"$voucher\"
				>
				<button type=\"submit\">CONNECT</button>
			</form>
			<div class=\"plan\">
				<div class=\"plan-item\"><strong>&#8369;5</strong><span>PRICE</span></div>
				<div class=\"plan-item\"><strong>6 HOURS</strong><span>TIME</span></div>
				<div class=\"plan-item\"><strong>10 Mbps</strong><span>SPEED</span></div>
			</div>
		</section>
	"
}

thankyou_page() {
	# Encode voucher for BinAuth WITHOUT displaying it as visible text.
	# binauth_custom assignment is a plain (non-eval) assignment; encode_custom
	# runs quoted ndsctl b64encode (libopennds.sh). No shell interpretation
	# of the voucher content occurs here.
	binauth_custom="voucher=$voucher"
	encode_custom

	if [ -z "$custom" ]; then
		customhtml=""
	else
		customhtml="<input type=\"hidden\" name=\"custom\" value=\"$custom\">"
	fi

	# voucher/custom travel ONLY as hidden protocol fields (required by FAS).
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>VOUCHER RECEIVED</p>
			</div>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<input type=\"hidden\" name=\"voucher\" value=\"$voucher\">
				$customhtml
				<input type=\"hidden\" name=\"landing\" value=\"yes\">
				<button type=\"submit\">Continue</button>
			</form>
			<p class=\"note\">If this page closes automatically, reopen your browser to continue.</p>
		</section>
	"
}

landing_page() {
	originurl=$(printf "${originurl//%/\\x}")
	gatewayurl=$(printf "${gatewayurl//%/\\x}")

	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — voucher value deliberately NOT added to userinfo.
	userinfo="$userinfo, stage1-test-bypass (no validation)"

	# Stage 1 flow test: performs the standard auth call so BinAuth receives
	# the custom string. Success (if any) = existing stub default, NOT approval.
	auth_log

	# No voucher / custom values rendered below (browser-privacy requirement).
	# Verification happens server-side: binauthlog.log + ndsctl json (see test proc).
	auth_success="
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>REQUEST SENT</p>
			</div>
			<p class=\"note\">Your request was processed. You can use your browser as normal if access was granted.</p>
			<form class=\"voucher-form\" action=\"$gatewayurl\" method=\"get\">
				<button type=\"submit\">Continue</button>
			</form>
		</section>
	"
	auth_fail="
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>REQUEST FAILED</p>
			</div>
			<p class=\"note\">Something went wrong or the request timed out. Please try again.</p>
			<form class=\"voucher-form\" action=\"http://$gatewayfqdn\" method=\"get\">
				<button type=\"submit\">Try again</button>
			</form>
		</section>
	"

	if [ "$ndsstatus" = "authenticated" ]; then
		echo "$auth_success"
	else
		echo "$auth_fail"
	fi

	footer
}

#### end of functions ####


#################################################
#						#
#  Start - Main entry point for this Theme	#
#						#
#  Parameters set here overide those		#
#  set in libopennds.sh			#
#						#
#################################################

# Quotas and Data Rates (Stage 1: defaults; real rates/quotas are Stage 2)
# session_length in minutes; 0 = global sessiontimeout value.
session_length="0"

# rates in kb/s, quotas in kB; 0 = global value.
upload_rate="0"
download_rate="0"
upload_quota="0"
download_quota="0"

quotas="$session_length $upload_rate $download_rate $upload_quota $download_quota"

# NDS portal parameters expected from openNDS ($ndsparamlist base is set in libopennds.sh).
# Stage 1 needs no portal-wide custom params/images/files.
ndscustomparams=""
ndscustomimages=""
ndscustomfiles=""

ndsparamlist="$ndsparamlist $ndscustomparams $ndscustomimages $ndscustomfiles"

# FAS dialogue variables for this theme. "voucher" is the ONLY addition and is
# what makes libopennds get_arguments/parse_variables populate $voucher.
additionalthemevars="voucher"

fasvarlist="$fasvarlist $additionalthemevars"

# Do NOT set/encode binauth_custom here; thankyou_page() sets and encodes it
# per-submission so each voucher value flows independently.
#binauth_custom=""
#encode_custom

# Log marker only (see privacy note above).
userinfo="$title, stage1-test-bypass (no validation)"
```

## 9. Ask ChatGPT to confirm

* [ ] FAS mechanism matches local `libopennds.sh`, not generic docs?
* [ ] `additionalthemevars="voucher"` sufficient for `$voucher`?
* [ ] Two-step `login → thankyou(encode) → landing(auth)` required and correct?
* [ ] Hidden `fas`/`voucher`/`custom`/`landing` fields complete, no missing field?
* [ ] CPD-safe (inline CSS, no JS/CDN/href/`splash.css`)?
* [ ] No unsafe shell use (`eval`, backticks, direct `ndsctl`, unquoted voucher in command)?
* [ ] `PORTAL-TEST` comment-only, no hard-coded allow?
* [ ] No visible voucher/custom leak beyond required hidden fields?
* [ ] Deploy/rollback safe, no port/firewall/LuCI/statuspath change?
* [ ] Test proves `custom` reaches BinAuth without claiming validation?
* [ ] No Stage 2 scope leaked?
