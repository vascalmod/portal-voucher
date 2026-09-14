#!/bin/sh
# tests/theme_voucher_test.sh — mock-render + gating tests for theme_voucher.sh
# Stubs library/transport/daemon calls; no network, no EAP.
# Run: sh tests/theme_voucher_test.sh
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0

# Fixed clock: now=9912300000, stub session_end=9912345678 -> timer 12:41:18.
THEME="$PWD/theme_voucher.sh"
mkdir -p /tmp/ndscids
: > /tmp/ndscids/ndsinfo
PSKFILE=$(mktemp)
printf 'dummy-test-psk' > "$PSKFILE"
export VOUCHER_API_URL="http://test.invalid/claim"
export VOUCHER_PSK_FILE="$PSKFILE"

# Source the real ThemeSpec (top level only assigns vars; libopennds does the
# same via `. $themespecpath`). Stubs below stand in for library/daemon calls.
load_theme() { . "$THEME"; }

# uclient-fetch cannot be a shell function (hyphen illegal in dash), so stub
# it as an executable on PATH printing $FETCH_RESP (mirrors EAP behavior)
# and counting invocations in $FETCHCOUNT for no-pre-fetch assertions.
# Request lines are appended to $URLFILE when set (endpoint/body assertions).
# Endpoint-aware: /session URLs get $FETCH_RESP_SESSION, everything else gets
# $FETCH_RESP (mirrors the two-step auto-relogin: session check, then resume).
STUBBIN=$(mktemp -d)
printf '#!/bin/sh\ncase "$*" in */session*) printf "%%s" "$FETCH_RESP_SESSION";; *) printf "%%s" "$FETCH_RESP";; esac\nprintf "%%s\\n" "$*" >> "${URLFILE:-/dev/null}"\necho call >> "${FETCHCOUNT:-/dev/null}"\n' > "$STUBBIN/uclient-fetch"
chmod +x "$STUBBIN/uclient-fetch"
PATH="$STUBBIN:$PATH"
export PATH

setup_stubs() {
	encode_custom() { custom="Q1VTVE9N"; }
	auth_log() {
		printf '%s|%s|%s' "$session_length" "$upload_rate" "$download_rate" > "$CALLREC"
		ndsstatus="$AUTH_RESULT"
	}
	configure_log_location() { mountpoint="/tmp"; }
	logger() { printf '%s\n' "$*" >> "${DENYLOG:-/dev/null}"; }
	date() {
		case "$1" in
			+%s) printf '9912300000' ;;
			+*) printf '2026' ;;
			*) command date "$@" ;;
		esac
	}
	ndsctl() {
		case "$1" in
			json) printf '{"session_end": "9912345678"}' ;;
			b64decode) printf '%s' "$2" ;;
		esac
	}
}

# render_login renders the empty-voucher view (never authenticates).
render_login() {
	(
		load_theme
		setup_stubs
		fas="TESTFAS" voucher="" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

# render_auto <session-resp> <resume-resp> <auth-result>
# Fresh-login view (no voucher, no resume flag): exercises ACTIVE auto-relogin.
render_auto() {
	(
		load_theme
		setup_stubs
		FETCH_RESP_SESSION="$1"
		FETCH_RESP="$2"
		AUTH_RESULT="$3"
		export FETCH_RESP_SESSION FETCH_RESP AUTH_RESULT
		fas="TESTFAS" voucher="" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

# render_resume_origin <fetch-resp> <auth-result> <originurl>
# Resume intent arriving ONLY inside originurl/cpi_query (as MHD delivers the
# PAUSED portal's ?resume=1 button: URL-encoded, entity-encoded by libopennds).
# $resume itself stays empty — the theme must still take the resume path.
render_resume_origin() {
	(
		load_theme
		setup_stubs
		FETCH_RESP="$1"
		AUTH_RESULT="$2"
		ORIGINURL="$3"
		export FETCH_RESP AUTH_RESULT
		fas="TESTFAS" voucher="" resume="" originurl="$ORIGINURL" cpi_query="$ORIGINURL"
		gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

# render_resume <fetch-resp> <auth-result>
# Codeless resume view (resume=1, no voucher): exercises voucher_resume_page.
render_resume() {
	(
		load_theme
		setup_stubs
		FETCH_RESP="$1"
		AUTH_RESULT="$2"
		export FETCH_RESP AUTH_RESULT
		fas="TESTFAS" voucher="" resume="1" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

# render_flow <fetch-resp> <auth-result> [voucher]
# Caller owns $CALLREC (mktemp -u path, exported): the auth_log stub records
# quotas there, proving whether the auth call happened and with what policy.
render_flow() {
	(
		load_theme
		setup_stubs
		FETCH_RESP="$1"
		AUTH_RESULT="$2"
		export FETCH_RESP AUTH_RESULT
		fas="TESTFAS" voucher="${3:-TEST-6H}" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null
}

check() {
	desc="$1"; cond="$2"
	if eval "$cond"; then
		PASS=$((PASS + 1)); echo "PASS: $desc"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $desc"
	fi
}

LOGIN_OUT=$(render_login)
STATUS_OUT=$(render_flow "ALLOW 21600 10240 10240" "authenticated")
DENIED_OUT=$(render_flow "DENY unknown" "authenticated")

# --- 1. login view unchanged ---
check "login-has-voucher-input" 'printf "%s" "$LOGIN_OUT" | grep -q "name=\"voucher\""'
check "login-has-connect" 'printf "%s" "$LOGIN_OUT" | grep -q "CONNECT"'
check "login-has-rates" 'printf "%s" "$LOGIN_OUT" | grep -q "rate-card" && [ "$(printf "%s" "$LOGIN_OUT" | grep -o "<div class=\"rate-card" | wc -l)" -eq 7 ]'
check "login-rates-tiers" 'for t in "8 Hours" "16 Hours" "36 Hours (1.5 Days)" "4 Days (96 Hours)" "9 Days" "19 Days" "30 Days (1 Month)"; do printf "%s" "$LOGIN_OUT" | grep -q "$t" || exit 1; done'
check "login-rates-speed" 'printf "%s" "$LOGIN_OUT" | grep -q "10 Mbps"'
check "login-rates-wide" '[ "$(printf "%s" "$LOGIN_OUT" | grep -o "<div class=\"rate-card rate-wide\"" | wc -l)" -eq 1 ]'
check "login-has-fas" 'printf "%s" "$LOGIN_OUT" | grep -q "name=\"fas\""'
check "login-no-thankyou" '! printf "%s" "$LOGIN_OUT" | grep -q "VOUCHER RECEIVED"'
check "login-no-status" '! printf "%s" "$LOGIN_OUT" | grep -q "CONNECTED"'
check "login-no-error-initially" '! printf "%s" "$LOGIN_OUT" | grep -q "<div class=\"form-error\""'
check "zone-preset-skips-probe" '( load_theme; [ "$client_zone" = "Wi-Fi" ] )'

# --- 2. CONNECT goes straight to custom status (no Continue tap) ---
check "status-connected" 'printf "%s" "$STATUS_OUT" | grep -q "CONNECTED"'
check "status-redirect-target" 'printf "%s" "$STATUS_OUT" | grep -q "http://10.0.0.1/"'
check "status-redirect-meta" 'printf "%s" "$STATUS_OUT" | grep "refresh" | grep -q "url=http://10.0.0.1/"'
check "status-redirect-js" 'printf "%s" "$STATUS_OUT" | grep -q "location.replace"'
check "status-no-button" '! printf "%s" "$STATUS_OUT" | grep -q "<button"'
check "status-hides-voucher" '! printf "%s" "$STATUS_OUT" | grep -q "TEST-6H"'
check "status-no-voucher-field" '! printf "%s" "$STATUS_OUT" | grep -q "voucher="'
check "status-no-thankyou" '! printf "%s" "$STATUS_OUT" | grep -q "VOUCHER RECEIVED"'
check "status-no-landing-field" '! printf "%s" "$STATUS_OUT" | grep -q "landing"'

# --- 3. gating: auth call happens ONLY on backend ALLOW, with policy quotas ---
# (CALLREC owned outside each render: footer exits inside the subshell.)
ALLOW_CALLREC=$(mktemp)
ALLOW_CALL_OUT=$(export CALLREC="$ALLOW_CALLREC"; render_flow "ALLOW 21600 10240 10240" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$ALLOW_CALLREC")"; rm -f "$ALLOW_CALLREC")
DENY_CALLREC=$(mktemp)
DENY_CALL_OUT=$(export CALLREC="$DENY_CALLREC"; render_flow "DENY unknown" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$DENY_CALLREC")"; rm -f "$DENY_CALLREC")
FAILCALLREC=$(mktemp)
FAILCALL_OUT=$(export CALLREC="$FAILCALLREC"; render_flow "" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$FAILCALLREC")"; rm -f "$FAILCALLREC")
check "allow-calls-auth-with-policy" 'printf "%s" "$ALLOW_CALL_OUT" | grep -q "CALL=360|10240|10240"'
check "deny-skips-auth-call" 'printf "%s" "$DENY_CALL_OUT" | grep -q "CALL=$"'
check "fetch-fail-skips-auth-call" 'printf "%s" "$FAILCALL_OUT" | grep -q "CALL=$"'
check "denied-invalid-title" 'printf "%s" "$DENIED_OUT" | grep -q "INVALID VOUCHER"'
check "denied-invalid-text" 'printf "%s" "$DENIED_OUT" | grep -q "not valid"'
check "denied-inline-error-block" 'printf "%s" "$DENIED_OUT" | grep -q "<div class=\"form-error\""'
check "denied-preserves-code" 'printf "%s" "$DENIED_OUT" | grep -q "value=\"TEST-6H\""'
check "denied-stays-login-form" 'printf "%s" "$DENIED_OUT" | grep -q "name=\"voucher\""'
check "denied-no-timer" '! printf "%s" "$DENIED_OUT" | grep -q "REMAINING"'

# --- 4. json outage degrades (CONNECTED, no fabricated timer) ---
NOJSON_OUT=$( (
	load_theme
	setup_stubs
	ndsctl() { printf ''; }
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC=$(mktemp); export CALLREC
	fas="TESTFAS" voucher="TEST-6H" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	header
	voucher_login
) 2>/dev/null )
check "nojson-still-redirects" 'printf "%s" "$NOJSON_OUT" | grep -q "http://10.0.0.1/"'

# --- 5. CPD safety: inline CSS present, no JS/href leftovers ---
check "css-redirect-card" 'printf "%s" "$STATUS_OUT" | grep -q "load-spinner" && printf "%s" "$STATUS_OUT" | grep -q "voucher-form"'
check "no-href" '! printf "%s" "$STATUS_OUT" | grep -qi "href"'
check "no-onclick" '! printf "%s" "$STATUS_OUT" | grep -qi "onclick"'
check "status-single-script" '[ "$(printf "%s" "$STATUS_OUT" | grep -o "<script>" | wc -l)" -eq 1 ]'

# --- 6. legacy paths hardened: landing requires voucher + ALLOW ---
# (CALLREC owned outside: landing_page ends in footer->exit, so the record is
# read after the subshell completes.)
LEGACY_OK_CALLREC=$(mktemp)
LEGACY_OK=$( (
	load_theme
	setup_stubs
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC="$LEGACY_OK_CALLREC"; export CALLREC
	fas="TESTFAS" voucher="TEST-6H" landing="yes" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	landing_page
) 2>/dev/null )
LEGACY_OK="$LEGACY_OK CALL=$(cat "$LEGACY_OK_CALLREC")"; rm -f "$LEGACY_OK_CALLREC"
LEGACY_NOVOUCHER_CALLREC=$(mktemp)
LEGACY_NOVOUCHER=$( (
	load_theme
	setup_stubs
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC="$LEGACY_NOVOUCHER_CALLREC"; export CALLREC
	fas="TESTFAS" voucher="" landing="yes" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	landing_page
) 2>/dev/null )
LEGACY_NOVOUCHER="$LEGACY_NOVOUCHER CALL=$(cat "$LEGACY_NOVOUCHER_CALLREC")"; rm -f "$LEGACY_NOVOUCHER_CALLREC"
LEGACY_DENY_CALLREC=$(mktemp)
LEGACY_DENY=$( (
	load_theme
	setup_stubs
	FETCH_RESP="DENY unknown" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	CALLREC="$LEGACY_DENY_CALLREC"; export CALLREC
	fas="TESTFAS" voucher="TEST-6H" landing="yes" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	landing_page
) 2>/dev/null )
LEGACY_DENY="$LEGACY_DENY CALL=$(cat "$LEGACY_DENY_CALLREC")"; rm -f "$LEGACY_DENY_CALLREC"
check "legacy-allow-calls-auth" 'printf "%s" "$LEGACY_OK" | grep -q "CALL=360|10240|10240"'
check "legacy-allow-redirects" 'printf "%s" "$LEGACY_OK" | grep -q "http://10.0.0.1/"'
check "legacy-no-voucher-skips-auth" 'printf "%s" "$LEGACY_NOVOUCHER" | grep -q "CALL=$"'
check "legacy-no-voucher-required" 'printf "%s" "$LEGACY_NOVOUCHER" | grep -q "VOUCHER REQUIRED"'
check "legacy-deny-skips-auth" 'printf "%s" "$LEGACY_DENY" | grep -q "CALL=$"'

# --- 7. reason-mapped errors (fixed vocabulary, anti-enumeration) ---
# helper: render a denied flow for a backend reason; sets DENYOUT/DENYLOGOUT
render_denied() {
	DENYLOG_F=$(mktemp); export DENYLOG_F
	DENYOUT=$( (
		load_theme
		setup_stubs
		FETCH_RESP="DENY $1" AUTH_RESULT="authenticated"
		export FETCH_RESP AUTH_RESULT
		DENYLOG="$DENYLOG_F"; export DENYLOG
		CALLREC=$(mktemp); export CALLREC
		fas="TESTFAS" voucher="TEST-6H" gatewayfqdn="status.client"
		gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
		header
		voucher_login
	) 2>/dev/null )
	DENYLOGOUT=$(cat "$DENYLOG_F"); rm -f "$DENYLOG_F"
	export DENYOUT DENYLOGOUT
}
render_denied "expired"
check "expired-title" 'printf "%s" "$DENYOUT" | grep -q "VOUCHER EXPIRED"'
check "expired-text" 'printf "%s" "$DENYOUT" | grep -q "used up"'
check "expired-not-invalid" '! printf "%s" "$DENYOUT" | grep -q "not valid"'
check "expired-logged" 'printf "%s" "$DENYLOGOUT" | grep -q "why=expired"'
check "expired-inline-login" 'printf "%s" "$DENYOUT" | grep -q "name=\"voucher\""'
EXPIRED_PAGE_OUT=$( ( load_theme; setup_stubs; fas="TESTFAS" gatewayfqdn="status.client"; gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"; header; voucher_expired_page ) 2>/dev/null )
check "expired-page-rates" 'printf "%s" "$EXPIRED_PAGE_OUT" | grep -q "rate-card" && [ "$(printf "%s" "$EXPIRED_PAGE_OUT" | grep -o "<div class=\"rate-card" | wc -l)" -eq 7 ]'
render_denied "paused"
check "paused-title" 'printf "%s" "$DENYOUT" | grep -q "VOUCHER IN USE"'
check "paused-text" 'printf "%s" "$DENYOUT" | grep -q "another device"'
check "paused-logged" 'printf "%s" "$DENYLOGOUT" | grep -q "why=paused"'
render_denied "invalid"
check "invalid-shares-text-with-unknown" 'printf "%s" "$DENYOUT" | grep -q "not valid"'
render_denied "disabled"
check "disabled-shares-text-with-unknown" 'printf "%s" "$DENYOUT" | grep -q "not valid"'
# Anti-oracle property, stated exactly: unknown / invalid / disabled render
# byte-identical pages (compare against a fresh unknown render).
UNKNOWNOUT=$( (
	load_theme
	setup_stubs
	FETCH_RESP="DENY unknown" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	DENYLOG=/dev/null; export DENYLOG
	fas="TESTFAS" voucher="TEST-6H" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	header
	voucher_login
) 2>/dev/null )
check "disabled-identical-to-unknown" '[ "$DENYOUT" = "$UNKNOWNOUT" ]'
render_denied "mysterycode"
check "unknown-reason-falls-back-retry" 'printf "%s" "$DENYOUT" | grep -q "REQUEST FAILED"'
check "unknown-reason-no-leak" '! printf "%s" "$DENYOUT" | grep -qi "mysterycode"'
# malformed input never reaches the network
BADFMT_COUNT=$(mktemp); export FETCHCOUNT="$BADFMT_COUNT"
BADFMT_OUT=$( (
	load_theme
	setup_stubs
	FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated"
	export FETCH_RESP AUTH_RESULT
	fas="TESTFAS" voucher="A;B" gatewayfqdn="status.client"
	gatewayname="TestGW" clientip="10.0.0.200" clientmac="AA:BB:CC:DD:EE:01"
	header
	voucher_login
) 2>/dev/null )
check "badformat-invalid-text" 'printf "%s" "$BADFMT_OUT" | grep -q "not valid"'
check "badformat-no-fetch" '[ ! -s "$BADFMT_COUNT" ]'
rm -f "$BADFMT_COUNT"; unset FETCHCOUNT

# --- 8. loading state: spinner + disabled + relabel, progressive only ---
check "login-loading-markup" 'printf "%s" "$LOGIN_OUT" | grep -q "onsubmit=\"return voucherSubmit(this)\"" && printf "%s" "$LOGIN_OUT" | grep -q "btn-spinner" && printf "%s" "$LOGIN_OUT" | grep -q "btn-text"'
check "login-loading-script" 'printf "%s" "$LOGIN_OUT" | grep -q "function voucherSubmit" && printf "%s" "$LOGIN_OUT" | grep -q "pageshow"'
check "login-loading-css" 'printf "%s" "$LOGIN_OUT" | grep -q "btn-spinner" && printf "%s" "$LOGIN_OUT" | grep -q "vspin" && printf "%s" "$LOGIN_OUT" | grep -q "button:disabled"'
check "denied-loading-markup" 'printf "%s" "$DENIED_OUT" | grep -q "btn-spinner"'
check "status-no-loading-needed" '! printf "%s" "$STATUS_OUT" | grep -q "voucherSubmit"'
THANKYOU_OUT=$( (
	load_theme
	setup_stubs
	ndsctl() { printf ''; }
	fas="TESTFAS" voucher="TEST-6H" custom="" gatewayfqdn="status.client"
	thankyou_page
) 2>/dev/null )
check "thankyou-loading-markup" 'printf "%s" "$THANKYOU_OUT" | grep -q "AUTHENTICATING" && printf "%s" "$THANKYOU_OUT" | grep -q "btn-spinner"'

# --- 8b. codeless resume (resume=1, no voucher): pre-checks /resume, grants ---
check "resume-var-wired" '( load_theme; case "$additionalthemevars" in *resume*) true;; *) false;; esac )'
RESUME_OUT=$(render_resume "ALLOW 21177 10240 10240" "authenticated")
check "resume-redirects" 'printf "%s" "$RESUME_OUT" | grep -q "http://10.0.0.1/"'
check "resume-no-voucher-field" '! printf "%s" "$RESUME_OUT" | grep -q "name=\"voucher\""'
check "resume-no-code-leak" '! printf "%s" "$RESUME_OUT" | grep -q "voucher="'
RESUME_CALLREC=$(mktemp)
RESUME_CALL_OUT=$(export CALLREC="$RESUME_CALLREC"; render_resume "ALLOW 21177 10240 10240" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$RESUME_CALLREC")"; rm -f "$RESUME_CALLREC")
check "resume-allow-calls-auth-with-policy" 'printf "%s" "$RESUME_CALL_OUT" | grep -q "CALL=353|10240|10240"'
RESUME_URLFILE=$(mktemp); export URLFILE="$RESUME_URLFILE"
render_resume "ALLOW 21177 10240 10240" "authenticated" >/dev/null 2>&1
check "resume-posts-to-resume-endpoint" 'grep -q "/resume" "$RESUME_URLFILE"'
check "resume-post-carries-mac" 'grep -q "mac=AA:BB:CC:DD:EE:01" "$RESUME_URLFILE"'
check "resume-post-carries-no-voucher" '! grep -q "voucher=" "$RESUME_URLFILE"'
rm -f "$RESUME_URLFILE"; unset URLFILE
RESUME_EXPIRED_CALLREC=$(mktemp)
RESUME_EXPIRED=$(export CALLREC="$RESUME_EXPIRED_CALLREC"; render_resume "DENY expired" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$RESUME_EXPIRED_CALLREC")"; rm -f "$RESUME_EXPIRED_CALLREC")
check "resume-expired-banner" 'printf "%s" "$RESUME_EXPIRED" | grep -q "VOUCHER EXPIRED"'
check "resume-expired-skips-auth" 'printf "%s" "$RESUME_EXPIRED" | grep -q "CALL=$"'
check "resume-expired-stays-login" 'printf "%s" "$RESUME_EXPIRED" | grep -q "name=\"voucher\""'
RESUME_NOMATCH_CALLREC=$(mktemp)
RESUME_NOMATCH=$(export CALLREC="$RESUME_NOMATCH_CALLREC"; render_resume "DENY nomatch" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$RESUME_NOMATCH_CALLREC")"; rm -f "$RESUME_NOMATCH_CALLREC")
check "resume-nomatch-plain-login" 'printf "%s" "$RESUME_NOMATCH" | grep -q "name=\"voucher\""'
check "resume-nomatch-no-error-banner" '! printf "%s" "$RESUME_NOMATCH" | grep -q "<div class=\"form-error\""'
check "resume-nomatch-skips-auth" 'printf "%s" "$RESUME_NOMATCH" | grep -q "CALL=$"'
RESUME_BAD_CALLREC=$(mktemp)
RESUME_BAD=$(export CALLREC="$RESUME_BAD_CALLREC"; render_resume "GARBAGE" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$RESUME_BAD_CALLREC")"; rm -f "$RESUME_BAD_CALLREC")
check "resume-badreply-retry" 'printf "%s" "$RESUME_BAD" | grep -q "REQUEST FAILED"'
check "resume-badreply-skips-auth" 'printf "%s" "$RESUME_BAD" | grep -q "CALL=$"'
# strict-binding claim denial surfaces as IN USE (same text as paused)
render_denied "bound"
check "bound-title" 'printf "%s" "$DENYOUT" | grep -q "VOUCHER IN USE"'
check "bound-text" 'printf "%s" "$DENYOUT" | grep -q "another device"'

# --- 8b2. resume intent via originurl only (live-MHD shape, $resume empty) ---
ORIGIN_CALLREC=$(mktemp)
ORIGIN_OUT=$(export CALLREC="$ORIGIN_CALLREC"; render_resume_origin "ALLOW 21177 10240 10240" "authenticated" "http://status.client/login?resume=1" 2>/dev/null; printf 'CALL=%s' "$(cat "$ORIGIN_CALLREC")"; rm -f "$ORIGIN_CALLREC")
check "origin-resume-redirects" 'printf "%s" "$ORIGIN_OUT" | grep -q "http://10.0.0.1/"'
check "origin-resume-calls-auth" 'printf "%s" "$ORIGIN_OUT" | grep -q "CALL=353|10240|10240"'
check "origin-resume-no-voucher-field" '! printf "%s" "$ORIGIN_OUT" | grep -q "name=\"voucher\""'
ENCODED_CALLREC=$(mktemp)
ENCODED_OUT=$(export CALLREC="$ENCODED_CALLREC"; render_resume_origin "ALLOW 21177 10240 10240" "authenticated" "http&#37;3A&#37;2F&#37;2Fstatus.client&#37;2Flogin&#37;3Fresume&#37;3D1" 2>/dev/null; printf 'CALL=%s' "$(cat "$ENCODED_CALLREC")"; rm -f "$ENCODED_CALLREC")
check "origin-encoded-resume-redirects" 'printf "%s" "$ENCODED_OUT" | grep -q "http://10.0.0.1/"'
check "origin-encoded-resume-calls-auth" 'printf "%s" "$ENCODED_OUT" | grep -q "CALL=353|10240|10240"'
PLAIN_CALLREC=$(mktemp)
PLAIN_OUT=$(export CALLREC="$PLAIN_CALLREC"; render_resume_origin "ALLOW 21177 10240 10240" "authenticated" "http://status.client/" 2>/dev/null; printf 'CALL=%s' "$(cat "$PLAIN_CALLREC")"; rm -f "$PLAIN_CALLREC")
check "origin-plain-stays-login" 'printf "%s" "$PLAIN_OUT" | grep -q "name=\"voucher\""'
check "origin-plain-no-grant" 'printf "%s" "$PLAIN_OUT" | grep -q "CALL=$"'

# --- 8c. ACTIVE auto-relogin (fresh login, no voucher, no resume flag) ---
AUTO_ACTIVE_URLFILE=$(mktemp); export URLFILE="$AUTO_ACTIVE_URLFILE"
AUTO_OUT=$(render_auto '{"paused": false, "active": true, "remaining_seconds": 20724}' "ALLOW 20724 10240 10240" "authenticated" 2>/dev/null)
check "auto-active-redirects" 'printf "%s" "$AUTO_OUT" | grep -q "http://10.0.0.1/"'
check "auto-active-no-voucher-field" '! printf "%s" "$AUTO_OUT" | grep -q "name=\"voucher\""'
check "auto-active-no-code-leak" '! printf "%s" "$AUTO_OUT" | grep -q "voucher="'
check "auto-active-hits-session" 'grep -q "/session" "$AUTO_ACTIVE_URLFILE"'
check "auto-active-then-resume" 'grep -q "/resume" "$AUTO_ACTIVE_URLFILE"'
check "auto-active-session-first" '[ "$(grep -n "/session" "$AUTO_ACTIVE_URLFILE" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "/resume" "$AUTO_ACTIVE_URLFILE" | head -n 1 | cut -d: -f1)" ]'
check "auto-session-post-carries-no-voucher" '! grep "/session" "$AUTO_ACTIVE_URLFILE" | grep -q "voucher="'
rm -f "$AUTO_ACTIVE_URLFILE"; unset URLFILE
AUTO_CALLREC=$(mktemp)
AUTO_CALL_OUT=$(export CALLREC="$AUTO_CALLREC"; render_auto '{"paused": false, "active": true, "remaining_seconds": 20724}' "ALLOW 20724 10240 10240" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$AUTO_CALLREC")"; rm -f "$AUTO_CALLREC")
check "auto-active-calls-auth-with-policy" 'printf "%s" "$AUTO_CALL_OUT" | grep -q "CALL=346|10240|10240"'
AUTO_PAUSED_URLFILE=$(mktemp); export URLFILE="$AUTO_PAUSED_URLFILE"
AUTO_PAUSED_CALLREC=$(mktemp)
AUTO_PAUSED_DENYLOG=$(mktemp)
AUTO_PAUSED=$(export CALLREC="$AUTO_PAUSED_CALLREC"; DENYLOG="$AUTO_PAUSED_DENYLOG"; export DENYLOG; render_auto '{"paused": true, "active": false, "remaining_seconds": 321}' "ALLOW 321 10240 10240" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$AUTO_PAUSED_CALLREC")"; rm -f "$AUTO_PAUSED_CALLREC")
check "auto-paused-confirm" 'printf "%s" "$AUTO_PAUSED" | grep -q "PAUSED SESSION FOUND"'
check "auto-paused-frozen-shown" 'printf "%s" "$AUTO_PAUSED" | grep -q "00:05:21"'
check "auto-paused-resume-form" 'printf "%s" "$AUTO_PAUSED" | grep -q "action=\"/opennds_preauth/\"" && printf "%s" "$AUTO_PAUSED" | grep -q "name=\"resume\""'
check "auto-paused-code-exit" 'printf "%s" "$AUTO_PAUSED" | grep -q "name=\"voucher\""'
check "auto-paused-no-grant" 'printf "%s" "$AUTO_PAUSED" | grep -q "CALL=$"'
check "auto-paused-no-redirect" '! printf "%s" "$AUTO_PAUSED" | grep -q "location.replace" && ! printf "%s" "$AUTO_PAUSED" | grep -q "http-equiv=\"refresh\""'
check "auto-paused-no-resume-call" '! grep -q "/resume" "$AUTO_PAUSED_URLFILE"'
check "auto-paused-logged" 'grep -q "paused-confirm" "$AUTO_PAUSED_DENYLOG"'
rm -f "$AUTO_PAUSED_URLFILE" "$AUTO_PAUSED_DENYLOG"; unset URLFILE DENYLOG
AUTO_EXPIRED_CALLREC=$(mktemp)
AUTO_EXPIRED_DENYLOG=$(mktemp)
AUTO_EXPIRED=$(export CALLREC="$AUTO_EXPIRED_CALLREC"; DENYLOG="$AUTO_EXPIRED_DENYLOG"; export DENYLOG; render_auto '{"paused": false, "active": false, "remaining_seconds": 0, "expired": true}' "" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$AUTO_EXPIRED_CALLREC")"; rm -f "$AUTO_EXPIRED_CALLREC")
check "auto-expired-page" 'printf "%s" "$AUTO_EXPIRED" | grep -q "TIME USED UP"'
check "auto-expired-new-code-form" 'printf "%s" "$AUTO_EXPIRED" | grep -q "name=\"voucher\""'
check "auto-expired-no-grant" 'printf "%s" "$AUTO_EXPIRED" | grep -q "CALL=$"'
check "auto-expired-no-redirect" '! printf "%s" "$AUTO_EXPIRED" | grep -q "location.replace"'
check "auto-expired-logged" 'grep -q "expired-shown" "$AUTO_EXPIRED_DENYLOG"'
rm -f "$AUTO_EXPIRED_DENYLOG"; unset DENYLOG
AUTO_ZERO_CALLREC=$(mktemp)
AUTO_ZERO=$(export CALLREC="$AUTO_ZERO_CALLREC"; render_auto '{"paused": true, "active": false, "remaining_seconds": 0}' "" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$AUTO_ZERO_CALLREC")"; rm -f "$AUTO_ZERO_CALLREC")
check "auto-zero-balance-expired" 'printf "%s" "$AUTO_ZERO" | grep -q "TIME USED UP"'
check "auto-zero-no-grant" 'printf "%s" "$AUTO_ZERO" | grep -q "CALL=$"'
AUTO_NONE_CALLREC=$(mktemp)
AUTO_NONE=$(export CALLREC="$AUTO_NONE_CALLREC"; render_auto '{"paused": false, "active": false, "remaining_seconds": 0}' "" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$AUTO_NONE_CALLREC")"; rm -f "$AUTO_NONE_CALLREC")
check "auto-nomatch-stays-login" 'printf "%s" "$AUTO_NONE" | grep -q "name=\"voucher\""'
check "auto-nomatch-no-grant" 'printf "%s" "$AUTO_NONE" | grep -q "CALL=$"'
AUTO_EMPTY_CALLREC=$(mktemp)
AUTO_EMPTY=$(export CALLREC="$AUTO_EMPTY_CALLREC"; render_auto "" "" "authenticated" 2>/dev/null; printf 'CALL=%s' "$(cat "$AUTO_EMPTY_CALLREC")"; rm -f "$AUTO_EMPTY_CALLREC")
check "auto-unreachable-stays-login" 'printf "%s" "$AUTO_EMPTY" | grep -q "name=\"voucher\""'
check "auto-unreachable-no-grant" 'printf "%s" "$AUTO_EMPTY" | grep -q "CALL=$"'
VOUCHER_URLFILE=$(mktemp); export URLFILE="$VOUCHER_URLFILE"
export CALLREC=$(mktemp)
FETCH_RESP="ALLOW 21600 10240 10240" AUTH_RESULT="authenticated" render_flow "ALLOW 21600 10240 10240" "authenticated" >/dev/null 2>&1
check "auto-voucher-path-skips-session-check" '! grep -q "/session" "$VOUCHER_URLFILE"'
rm -f "$VOUCHER_URLFILE" "$CALLREC"; unset URLFILE CALLREC

# --- 9. inline scripts are real syntax (node --check when available) ---
if command -v node >/dev/null 2>&1; then
	printf '%s' "$STATUS_OUT $LOGIN_OUT $DENIED_OUT" | grep -o "<script>.*</script>" | sed "s|<script>||;s|</script>||" > /tmp/jsblocks.txt
	JSN=0; JSFAIL=0
	while IFS= read -r jsline; do
		[ -z "$jsline" ] && continue
		JSN=$((JSN + 1))
		printf '%s' "$jsline" > /tmp/jsblock.js
		node --check /tmp/jsblock.js 2>/dev/null || JSFAIL=$((JSFAIL + 1))
	done < /tmp/jsblocks.txt
	rm -f /tmp/jsblocks.txt /tmp/jsblock.js
	[ "$JSN" -ge 1 ] && [ "$JSFAIL" -eq 0 ]
	check "inline-js-syntax-ok" '[ "$JSN" -ge 1 ] && [ "$JSFAIL" -eq 0 ]'
else
	echo "SKIP: node absent, inline-js-syntax-ok not run"
fi

rm -f /tmp/ndscids/ndsinfo "$PSKFILE"
rm -rf "$STUBBIN"
echo "---- theme_voucher: PASS=$PASS FAIL=$FAIL ----"
[ "$FAIL" -eq 0 ]
