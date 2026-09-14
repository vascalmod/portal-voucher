#!/bin/sh
# tests/client_params_voucher_test.sh — mock tests for client_params_voucher.sh
# Runs the real file as a subprocess with stubbed ndsctl/libopennds.sh/date.
# No network, no EAP. Run: sh tests/client_params_voucher_test.sh
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0

FILE="$PWD/client_params_voucher.sh"
STUBBIN=$(mktemp -d)
mkdir -p /tmp/ndscids
printf 'gatewayname="TestGW"\nversion="10.3.1"\n' > /tmp/ndscids/ndsinfo

# Fixed clock: date +%s -> 9912300000. Authed fixture end 9912345678 (timer 12:41:18).
cat > "$STUBBIN/date" <<'EOF'
#!/bin/sh
case "$1" in
	+%s) printf '9912300000' ;;
	+*) printf '2026' ;;
	*) exec /bin/date "$@" ;;
esac
EOF
cat > "$STUBBIN/ndsctl" <<'EOF'
#!/bin/sh
if [ "$1" = "json" ]; then
	printf '%s' "$JSON_RESP"
elif [ "$1" = "b64decode" ]; then
	printf '%s' "$2" | base64 -d 2>/dev/null
else
	exit 1
fi
EOF
cat > "$STUBBIN/uclient-fetch" <<'EOF'
#!/bin/sh
printf '%s' "$VAPI_RESP"
EOF
cat > "$STUBBIN/libopennds.sh" <<'EOF'
#!/bin/sh
if [ "$1" = "tmpfs" ]; then
	printf '/tmp'
fi
exit 0
EOF
cat > "$STUBBIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${LOGGER_FILE:-/dev/null}"
EOF
cat > "$STUBBIN/iw" <<'EOF'
#!/bin/sh
# stub iw for band display: $IW_DEV feeds `iw dev`; a station hit happens only
# when $IW_HIT names the queried interface; `info` reports $IW_MHZ MHz;
# $IW_FAIL makes every call fail (missing-driver behavior).
if [ -n "$IW_FAIL" ]; then exit 1; fi
if [ "$1" = "dev" ] && [ $# -eq 1 ]; then printf '%s' "$IW_DEV"; exit 0; fi
if [ "$1" = "dev" ] && [ "$3" = "station" ] && [ "$4" = "get" ]; then
	if [ -n "$IW_HIT" ] && [ "$2" = "$IW_HIT" ]; then
		printf 'Station %s (on %s)\n\tassociated:\tyes\n' "$5" "$2"
		exit 0
	fi
	echo "command failed: No such file or directory (-2)" >&2
	exit 1
fi
if [ "$1" = "dev" ] && [ "$3" = "info" ]; then
	printf 'Interface %s\n\tchannel %s (%s MHz), width: 20 MHz\n' "$2" "$IW_CH" "$IW_MHZ"
	exit 0
fi
exit 1
EOF
chmod +x "$STUBBIN/date" "$STUBBIN/ndsctl" "$STUBBIN/uclient-fetch" "$STUBBIN/libopennds.sh" "$STUBBIN/logger" "$STUBBIN/iw"
PSKFILE=$(mktemp)
printf 'test-psk' > "$PSKFILE"

# run_status <json-variant> : prints page stdout. Caller sets JSON_RESP.
run_status() {
	JSON_RESP="$1"
	export JSON_RESP
	PATH="$STUBBIN:$PATH" sh "$FILE" status 10.0.0.200 "" 2>/dev/null
}

run_err511() {
	b64query=$(printf '%s' "$1" | base64 | tr -d '\n')
	VAPI_RESP="$2"
	export VOUCHER_API_URL="http://127.0.0.1:8080/claim" VOUCHER_PSK_FILE="$PSKFILE" VAPI_RESP OPENNDS_LIBOPENNDS="$STUBBIN/libopennds.sh"
	PATH="$STUBBIN:$PATH" sh "$FILE" err511 10.0.0.200 "$b64query" 2>/dev/null
}

# run_err511_noquery <json> <vapi-resp> : err511 with an EMPTY FAS query, as
# MHD delivers direct gateway visits (10.0.0.1 refresh/reconnect). The MAC
# must then come from the daemon json record, or the paused RESUME UI is
# missed and the client wrongly gets the login forward (live-EAP regression).
run_err511_noquery() {
	JSON_RESP="$1"
	VAPI_RESP="$2"
	export JSON_RESP
	export VOUCHER_API_URL="http://127.0.0.1:8080/claim" VOUCHER_PSK_FILE="$PSKFILE" VAPI_RESP OPENNDS_LIBOPENNDS="$STUBBIN/libopennds.sh"
	PATH="$STUBBIN:$PATH" sh "$FILE" err511 10.0.0.200 "" 2>/dev/null
}

check() {
	desc="$1"; cond="$2"
	if eval "$cond"; then
		PASS=$((PASS + 1)); echo "PASS: $desc"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $desc"
	fi
}

# NOTE: fixtures MUST be pretty-printed one-param-per-line, exactly like real
# `ndsctl json` output: the stock parser takes awk $4 of the matched line, so
# single-line JSON would parse every param as the first value (even in stock).
mkjson() {
	# $1 state, $2 session_end raw (already quoted or null), $3 custom raw
	printf '{\n"gatewayname": "TestGW",\n"gatewayaddress": "10.0.0.1",\n"gatewayfqdn": "status.client",\n"mac": "AA:BB:CC:DD:EE:01",\n"version": "10.3.1",\n"ip": "10.0.0.200",\n"client_type": "cpd",\n"clientif": "br-lan",\n"session_start": "0",\n"session_end": %s,\n"last_active": "9912300000",\n"token": "tok",\n"state": "%s",\n"custom": %s\n}' "$2" "$1" "$3"
}
PREAUTH_JSON=$(mkjson "Preauthenticated" "null" "null")
AUTHED_JSON=$(mkjson "Authenticated" '"9912345678"' '"dm91Y2hlcj1URVNULTZI"')
RESUMED_JSON=$(mkjson "Authenticated" '"9912345678"' '"cmVzdW1l"')
RESUMESMUG_JSON=$(mkjson "Authenticated" '"9912345678"' '"cmVzdW1lPTE="')
EXPIRED_JSON=$(mkjson "Authenticated" '"9912299990"' '"dm91Y2hlcj1URVNULTZI"')
NOCUSTOM_JSON=$(mkjson "Authenticated" '"9912345678"' "null")
BADCUSTOM_JSON=$(mkjson "Authenticated" '"9912345678"' '"aGVsbG8="')

PREAUTH_OUT=$(run_status "$PREAUTH_JSON")
AUTHED_OUT=$(run_status "$AUTHED_JSON")
EXPIRED_OUT=$(run_status "$EXPIRED_JSON")
FAIL_OUT=$(run_status "")
NOCUSTOM_OUT=$(run_status "$NOCUSTOM_JSON")
BADCUSTOM_OUT=$(run_status "$BADCUSTOM_JSON")
ERR511_PAUSED_OUT=$(run_err511 "?clientmac=AA:BB:CC:DD:EE:01, clientip=10.0.0.200" '{"paused": true, "active": false, "remaining_seconds": 321}')

# --- 1. preauth -> auto-forward, zero clicks, no stock dump ---
# Painted loading state navigates on window load; meta + button survive.
check "forward-meta-refresh" 'printf "%s" "$PREAUTH_OUT" | grep "refresh" | grep -q "url=http://status.client/login"'
check "forward-no-button" '! printf "%s" "$PREAUTH_OUT" | grep -q "<button"'
check "forward-loading-state" 'printf "%s" "$PREAUTH_OUT" | grep -q "CREATING SESSION" && printf "%s" "$PREAUTH_OUT" | grep -q "load-spinner"'
check "forward-load-navigation" 'printf "%s" "$PREAUTH_OUT" | grep -q "addEventListener"'
check "forward-light-bg" 'printf "%s" "$PREAUTH_OUT" | grep -q "color-scheme"'
check "forward-brand" 'printf "%s" "$PREAUTH_OUT" | grep -q "WI-FI E-VOUCHER"'
check "forward-no-session-status" '! printf "%s" "$PREAUTH_OUT" | grep -q "Session Status"'
check "forward-no-account-dump" '! printf "%s" "$PREAUTH_OUT" | grep -q "MAC address"'
check "forward-no-voucher-form" '! printf "%s" "$PREAUTH_OUT" | grep -q "name=\"voucher\""'

# --- 2. authenticated -> custom status, never stock dump ---
check "status-connected" 'printf "%s" "$AUTHED_OUT" | grep -q "CONNECTED"'
check "status-timer" 'printf "%s" "$AUTHED_OUT" | grep -q "12:41:18"'
check "status-data-seconds" 'printf "%s" "$AUTHED_OUT" | grep -q "data-remaining=\"45678\""'
check "status-countdown-script" 'printf "%s" "$AUTHED_OUT" | grep -q "setInterval"'
check "status-nojs-fallback-intact" 'printf "%s" "$AUTHED_OUT" | sed "s|<script>.*</script>||" | grep -q "12:41:18"'
check "status-voucher-once" '[ "$(printf "%s" "$AUTHED_OUT" | grep -o "TEST-6H" | wc -l)" -eq 1 ]'
# --- resume-granted sessions (custom=b64 "resume"): Voucher row reads
# "Resumed session" (code stays hidden by design); lookalikes still dash.
RESUMED_OUT=$(run_status "$RESUMED_JSON")
RESUMESMUG_OUT=$(run_status "$RESUMESMUG_JSON")
check "resumed-label-once" '[ "$(printf "%s" "$RESUMED_OUT" | grep -o "Resumed session" | wc -l)" -eq 1 ]'
check "resumed-no-dash-voucher" '! printf "%s" "$RESUMED_OUT" | grep -q "<strong>-</strong>"'
check "resumed-still-connected" 'printf "%s" "$RESUMED_OUT" | grep -q "CONNECTED"'
check "resume-smuggle-dashes" 'printf "%s" "$RESUMESMUG_OUT" | grep -q "<strong>-</strong>"'
check "resume-smuggle-no-label" '! printf "%s" "$RESUMESMUG_OUT" | grep -q "Resumed session"'
check "status-logout-kept" 'printf "%s" "$AUTHED_OUT" | grep -q "action=\"http://status.client/opennds_deny/\""'
check "status-no-session-status" '! printf "%s" "$AUTHED_OUT" | grep -q "Session Status"'
check "status-no-account-dump" '! printf "%s" "$AUTHED_OUT" | grep -q "Average Download"'

# --- 3. expired -> forward, not authed UI ---
check "expired-forwards" 'printf "%s" "$EXPIRED_OUT" | grep -q "url=http://status.client/login"'
check "expired-no-connected" '! printf "%s" "$EXPIRED_OUT" | grep -q "CONNECTED"'

# --- 4. json failure -> forward (fail-closed to login, never stock dump) ---
# (host varies when json yields nothing; mechanism, not host, is asserted)
check "jsonfail-forwards" 'printf "%s" "$FAIL_OUT" | grep -q "url=.*/login"'
check "jsonfail-no-session-status" '! printf "%s" "$FAIL_OUT" | grep -q "Session Status"'

# --- 5. missing/non-voucher custom -> still CONNECTED, code blanked ---
check "nocustom-connected" 'printf "%s" "$NOCUSTOM_OUT" | grep -q "CONNECTED"'
check "nocustom-no-code" '! printf "%s" "$NOCUSTOM_OUT" | grep -q "TEST-6H"'
check "badcustom-connected" 'printf "%s" "$BADCUSTOM_OUT" | grep -q "CONNECTED"'
check "badcustom-no-hello" '! printf "%s" "$BADCUSTOM_OUT" | grep -q "hello"'

# --- 6. stock code provably preserved where kept; old entry pages gone ---
# err511 needs absolute EAP paths so its full render cannot execute locally;
# instead: (a) every KEPT stock region is verbatim, (b) the old entry pages
# are provably absent, (c) dispatch routes err511 to the tested forward page.
# Live EAP deploy exercises the real err511 render via CPD traffic.
STOCK="opennds/client_params.sh"
FORK="client_params_voucher.sh"
sed 's/[[:space:]]*$//' "$FORK" > /tmp/got.txt
: > /tmp/want.txt
stock_range() { sed -n "$1,$2p" "$STOCK" | sed 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' >> /tmp/want.txt; }
stock_range 9 29
stock_range 31 51
stock_range 53 70
stock_range 73 92
stock_range 94 102
stock_range 107 144
stock_range 146 171
stock_range 173 191
stock_range 194 201
stock_range 289 315
MISSING=$(grep -v -F -x -f /tmp/got.txt /tmp/want.txt | head -5)
check "stock-regions-verbatim" '[ -z "$MISSING" ]'
check "custom-in-allowlist" 'grep -q "token state custom upload_rate_limit_threshold" "$FORK"'
check "old-entry-pages-gone" '! grep -q "To login, click or tap" "$FORK"'
check "no-stock-dump" '! grep -q "Average Download" "$FORK"'
check "err511-dispatches-forward" 'grep -A60 "\"\$status\" = \"err511\"" "$FORK" | grep -q "voucher_forward_page"'
check "err511-paused-shows-paused" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "PAUSED"'
check "err511-paused-no-forward" '! printf "%s" "$ERR511_PAUSED_OUT" | grep -q "CREATING SESSION"'
check "err511-paused-remaining" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "00:05:21"'
# --- 6b. codeless resume: hidden resume intent, no code field, IP/MAC shown ---
check "err511-paused-resume-field" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "name=\"resume\""'
check "err511-paused-resume-target" 'printf "%s" "$ERR511_PAUSED_OUT" | grep "resume-form" | grep -q "/login"'
check "err511-paused-no-voucher-input" '! printf "%s" "$ERR511_PAUSED_OUT" | grep -q "name=\"voucher\""'
check "err511-paused-no-code-needed" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "no voucher code needed"'
check "err511-paused-shows-mac" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "AA:BB:CC:DD:EE:01"'
check "err511-paused-shows-ip" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "10.0.0.200"'
# --- 6d. structured portal decision log (spec 21): ip/mac/lookup/state/
# remaining/decision per outcome; MAC only, never the voucher code.
LOGFILE=$(mktemp); export LOGGER_FILE="$LOGFILE"
: > "$LOGFILE"
printf '%s' "$ERR511_PAUSED_OUT" > /dev/null
run_err511 "?clientmac=AA:BB:CC:DD:EE:01, clientip=10.0.0.200" '{"paused": true, "active": false, "remaining_seconds": 321}' > /dev/null
check "log-paused-resume" 'grep -q "decision=SHOW_RESUME" "$LOGFILE" && grep -q "mac=AA:BB:CC:DD:EE:01" "$LOGFILE" && grep -q "lookup=HIT" "$LOGFILE" && grep -q "remaining=321" "$LOGFILE"'
check "log-no-code-leak" '! grep -qi "voucher" "$LOGFILE"'
: > "$LOGFILE"
VAPI_RESP='{"paused": false, "active": false, "remaining_seconds": 0}'; export VAPI_RESP
run_status "$PREAUTH_JSON" > /dev/null
check "log-preauth-login" 'grep -q "decision=SHOW_LOGIN" "$LOGFILE"'
: > "$LOGFILE"
VAPI_RESP='{"paused": false, "active": true, "remaining_seconds": 45678}'; export VAPI_RESP
run_status "$AUTHED_JSON" > /dev/null
check "log-authed-status" 'grep -q "decision=SHOW_STATUS" "$LOGFILE"'
rm -f "$LOGFILE"; unset LOGGER_FILE

# --- 6c. empty FAS query (direct 10.0.0.1 refresh/reconnect): MAC must come
# from the daemon json record; paused still shows RESUME. Fixture mirrors the
# live EAP format exactly (pretty-printed, one param per line — the stock
# awk-$4 parser is line-oriented, single-line JSON would misparse).
NOQUERY_JSON=$(printf '{\n"gatewayname": "TestGW",\n"gatewayaddress": "10.0.0.1",\n"gatewayfqdn": "status.client",\n"mac":"AA:BB:CC:DD:EE:01",\n"version": "10.3.1",\n"ip": "10.0.0.200"\n}')
ERR511_NOQUERY_PAUSED_OUT=$(run_err511_noquery "$NOQUERY_JSON" '{"paused": true, "active": false, "remaining_seconds": 3593}')
check "noquery-paused-shows-paused" 'printf "%s" "$ERR511_NOQUERY_PAUSED_OUT" | grep -q "PAUSED"'
check "noquery-paused-no-forward" '! printf "%s" "$ERR511_NOQUERY_PAUSED_OUT" | grep -q "CREATING SESSION"'
check "noquery-paused-remaining" 'printf "%s" "$ERR511_NOQUERY_PAUSED_OUT" | grep -q "00:59:53"'
check "noquery-paused-resume-field" 'printf "%s" "$ERR511_NOQUERY_PAUSED_OUT" | grep -q "name=\"resume\""'
check "noquery-paused-no-voucher-input" '! printf "%s" "$ERR511_NOQUERY_PAUSED_OUT" | grep -q "name=\"voucher\""'
check "noquery-paused-shows-mac" 'printf "%s" "$ERR511_NOQUERY_PAUSED_OUT" | grep -q "AA:BB:CC:DD:EE:01"'
ERR511_NOQUERY_FWD_OUT=$(run_err511_noquery "$NOQUERY_JSON" '{"paused": false, "active": false, "remaining_seconds": 0}')
check "noquery-nopause-forwards" 'printf "%s" "$ERR511_NOQUERY_FWD_OUT" | grep -q "CREATING SESSION"'
check "noquery-nopause-no-paused" '! printf "%s" "$ERR511_NOQUERY_FWD_OUT" | grep -q "PAUSED"'
check "status-shows-mac" 'printf "%s" "$AUTHED_OUT" | grep -q "AA:BB:CC:DD:EE:01"'
check "status-shows-ip" 'printf "%s" "$AUTHED_OUT" | grep -q "10.0.0.200"'
# --- band display (iw-driven; EAP layout phy1-ap0/2.4G + phy0-ap0/5G) ---
IW_DEV_OUT=$(printf 'Interface phy1-ap0\nInterface phy0-ap0')
export IW_DEV_OUT
export IW_DEV="$IW_DEV_OUT" IW_CH=36 IW_MHZ=5180 IW_HIT="phy0-ap0"
BAND5_OUT=$(run_status "$AUTHED_JSON")
check "band-5ghz" 'printf "%s" "$BAND5_OUT" | grep -q "5 GHz"'
check "band-row-present" 'printf "%s" "$BAND5_OUT" | grep -q "<span>Band</span>"'
export IW_CH=11 IW_MHZ=2462 IW_HIT="phy1-ap0"
BAND2_OUT=$(run_status "$AUTHED_JSON")
check "band-24ghz" 'printf "%s" "$BAND2_OUT" | grep -q "2.4 GHz"'
export IW_FAIL=1
BANDFAIL_OUT=$(run_status "$AUTHED_JSON")
check "band-dash-no-iw" 'printf "%s" "$BANDFAIL_OUT" | grep -q "<strong>—</strong>"'
unset IW_FAIL
export IW_HIT="phy0-ap0" IW_CH=36 IW_MHZ="bogus"
BANDGARBAGE_OUT=$(run_status "$AUTHED_JSON")
check "band-dash-garbage" 'printf "%s" "$BANDGARBAGE_OUT" | grep -q "<strong>—</strong>"'
export IW_CH=36 IW_MHZ=5180
BANDPAUSED_OUT=$(run_err511 "?clientmac=AA:BB:CC:DD:EE:01, clientip=10.0.0.200" '{"paused": true, "active": false, "remaining_seconds": 321}')
check "band-paused-5ghz" 'printf "%s" "$BANDPAUSED_OUT" | grep -q "5 GHz"'
unset IW_DEV IW_DEV_OUT IW_CH IW_MHZ IW_HIT
rm -f /tmp/want.txt /tmp/got.txt

# --- 7. busy preserved ---
BUSY_OUT=$(PATH="$STUBBIN:$PATH" JSON_RESP="locked" sh "$FILE" status 10.0.0.200 "" 2>/dev/null)
check "busy-page" 'printf "%s" "$BUSY_OUT" | grep -qi "busy"'

# --- 8. navigation layering: instant JS + meta fallback, nothing else ---
check "forward-instant-nav" 'printf "%s" "$PREAUTH_OUT" | grep -q "location.replace"'
check "forward-single-script" '[ "$(printf "%s" "$PREAUTH_OUT" | grep -o "<script>" | wc -l)" -eq 1 ]'
check "forward-meta-fallback" 'printf "%s" "$PREAUTH_OUT" | grep "refresh" | grep -q "url=http://status.client/login"'
check "forward-no-href" '! printf "%s" "$PREAUTH_OUT" | grep -qi "href"'
check "status-no-href" '! printf "%s" "$AUTHED_OUT" | grep -qi "href"'
check "status-two-scripts" '[ "$(printf "%s" "$AUTHED_OUT" | grep -o "<script>" | wc -l)" -eq 2 ]'
check "status-countdown-plus-submit" 'printf "%s" "$AUTHED_OUT" | grep -q "setInterval" && printf "%s" "$AUTHED_OUT" | grep -q "function voucherSubmit\|voucherSubmit=function"'
check "status-inline-css" 'printf "%s" "$AUTHED_OUT" | grep -q "connection-status"'
# --- 8b. button busy-state on every portal action button ---
check "pause-loading-markup" 'printf "%s" "$AUTHED_OUT" | grep -q "onsubmit=\"return voucherSubmit(this)\"" && printf "%s" "$AUTHED_OUT" | grep -q "btn-spinner" && printf "%s" "$AUTHED_OUT" | grep -q "btn-text"'
check "pause-busy-label" 'printf "%s" "$AUTHED_OUT" | grep -q "data-busy=\"PAUSING"'
check "logout-busy-label" 'printf "%s" "$AUTHED_OUT" | grep -q "data-busy=\"LOGGING OUT"'
check "resume-busy-label" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "data-busy=\"RESUMING"'
check "resume-loading-markup" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "onsubmit=\"return voucherSubmit(this)\"" && printf "%s" "$ERR511_PAUSED_OUT" | grep -q "btn-spinner"'
check "paused-single-script" '[ "$(printf "%s" "$ERR511_PAUSED_OUT" | grep -o "<script>" | wc -l)" -eq 1 ]'
check "paused-loading-css" 'printf "%s" "$ERR511_PAUSED_OUT" | grep -q "btn-spinner" && printf "%s" "$ERR511_PAUSED_OUT" | grep -q "vspin" && printf "%s" "$ERR511_PAUSED_OUT" | grep -q "button:disabled"'
check "status-nojs-labels-intact" 'printf "%s" "$AUTHED_OUT" | sed "s|<script>.*</script>||" | grep -q "Pause" && printf "%s" "$AUTHED_OUT" | sed "s|<script>.*</script>||" | grep -q "Logout"'
check "paused-nojs-label-intact" 'printf "%s" "$ERR511_PAUSED_OUT" | sed "s|<script>.*</script>||" | grep -q "Resume"'

# --- 9. inline scripts are real syntax (node --check when available) ---
# Forward page now legitimately carries one script (load-time navigation),
# so the check counts scripts per page instead of assuming absence.
if command -v node >/dev/null 2>&1; then
	printf '%s' "$AUTHED_OUT $PREAUTH_OUT $ERR511_PAUSED_OUT" | grep -o "<script>.*</script>" | sed "s|<script>||;s|</script>||" > /tmp/jsblocks.txt
	JSN=0; JSFAIL=0
	while IFS= read -r jsline; do
		[ -z "$jsline" ] && continue
		JSN=$((JSN + 1))
		printf '%s' "$jsline" > /tmp/jsblock.js
		node --check /tmp/jsblock.js 2>/dev/null || JSFAIL=$((JSFAIL + 1))
	done < /tmp/jsblocks.txt
	rm -f /tmp/jsblocks.txt /tmp/jsblock.js
	check "inline-js-syntax-ok" '[ "$JSN" -ge 1 ] && [ "$JSFAIL" -eq 0 ]'
else
	echo "SKIP: node absent, inline-js-syntax-ok not run"
fi

rm -rf "$STUBBIN" "$PSKFILE" /tmp/ndscids/ndsinfo
echo "---- client_params_voucher: PASS=$PASS FAIL=$FAIL ----"
[ "$FAIL" -eq 0 ]
