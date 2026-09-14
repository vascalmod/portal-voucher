#!/bin/sh
# tests/custombinauth_test.sh — local harness for custombinauth.voucher.sh
# Stubs ndsctl/uclient-fetch/logger/daemon-hook; no network, no EAP, no secrets.
# Run: sh tests/custombinauth_test.sh
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0
STUB_RESP=""
EVICT_LOG=""

STUBBIN=$(mktemp -d)
CALLFILE=$(mktemp)
RESPFILE=$(mktemp)
printf '#!/bin/sh\necho call >> "$CALLFILE"\nprintf "%%s\\n" "$*" >> "${URLFILE:-/dev/null}"\ncat "$RESPFILE"\n' > "$STUBBIN/uclient-fetch"
chmod +x "$STUBBIN/uclient-fetch"
PATH="$STUBBIN:$PATH"
export CALLFILE RESPFILE
fetch_calls() { wc -l < "$CALLFILE" | tr -d ' '; }

ndsctl() {
	# only verb the script may use: b64decode <b64>
	if [ "$1" = "b64decode" ]; then
		printf '%s' "$2" | base64 -d 2>/dev/null
	fi
}
logger() { :; }

HOOK="$PWD/tests/stub_libopennds.sh"
printf '#!/bin/sh\necho "$@" >> "$EVICT_FILE"\n' > "$HOOK"
chmod +x "$HOOK"

b64() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }

# Static portability gate: the EAP runs busybox ash WITHOUT rev/tac/column.
# Any use below fails the suite before behavioral cases run.
if grep -n -E "(^|[^a-zA-Z_-])(rev|tac|column)( |$)" "$PWD/custombinauth.voucher.sh"; then
	echo "FAIL: non-busybox tool referenced"
	exit 1
fi

PSKFILE=$(mktemp)
printf 'dummy-psk' > "$PSKFILE"
export VOUCHER_API_URL="http://test.invalid/claim"
export VOUCHER_PSK_FILE="$PSKFILE"
export VOUCHER_TIMEOUT=5
export VOUCHER_LIBOPENDS="$HOOK"
export EVICT_FILE=$(mktemp)

# run_case <name> <action> <mac> <ip> <token> <custom-plain> <stub-resp> <want-exit> [want-sess] [want-calls]
run_case() {
	name="$1"; action="$2"; mac="$3"; ip="$4"; token="$5"; plain="$6"
	STUB_RESP="$7"; want_exit="$8"; want_sess="$9"; want_calls="${10}"
	printf '%s' "$STUB_RESP" > "$RESPFILE"
	: > "$CALLFILE"
	: > "$EVICT_FILE"
	(
		action="$action"
		custom=$(b64 "$plain")
		session_length=0; upload_rate=0; download_rate=0
		upload_quota=0; download_quota=0; exitlevel=0
		set -- "$action" "$mac" "redir" "ua" "$ip" "$token" "$custom"
		. "$PWD/custombinauth.voucher.sh"
		echo "$exitlevel|$session_length|$upload_rate|$download_rate"
	) > /tmp/cb_out.txt
	got=$(cat /tmp/cb_out.txt)
	got_exit=$(printf '%s' "$got" | cut -d'|' -f1)
	got_sess=$(printf '%s' "$got" | cut -d'|' -f2)
	got_calls=$(fetch_calls)
	ok=1
	[ "$got_exit" = "$want_exit" ] || ok=0
	{ [ -z "$want_sess" ] || [ "$got_sess" = "$want_sess" ]; } || ok=0
	{ [ -z "$want_calls" ] || [ "$got_calls" = "$want_calls" ]; } || ok=0
	if [ "$ok" -eq 1 ]; then
		PASS=$((PASS + 1)); echo "PASS: $name (exit=$got_exit sess=$got_sess calls=$got_calls)"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $name got=[$got/$got_calls] want_exit=$want_exit want_sess=$want_sess want_calls=$want_calls"
	fi
}

run_case "allow-fresh" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 0 360 1
run_case "deny-unknown" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=NOPE-1234" "DENY unknown" 1 0 1
run_case "deny-bad-charset" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=A;B" "" 1 0 0
run_case "deny-entity-smuggle" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=A&#59;B" "" 1 0 0
run_case "deny-backend-down" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "" 1 0 1
run_case "deny-bad-reply" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW lots fast faster" 1 0 1
run_case "ceil-21601-to-361" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21601 10240 10240" 0 361 1
run_case "deauth-passthrough" deauth AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "" 0 0 0
run_case "lowercase-normalized" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=test-6h" "ALLOW 21600 10240 10240" 0 360 1

# --- strict reply-shape vectors (all must DENY) ---
run_case "reply-bare-ALLOW" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW" 1 0 1
run_case "reply-alpha-remaining" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW abc 10240 10240" 1 0 1
run_case "reply-negative-remaining" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW -1 10240 10240" 1 0 1
run_case "reply-alpha-up" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 abc 10240" 1 0 1
run_case "reply-alpha-down" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 abc" 1 0 1
run_case "reply-random" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "RANDOM" 1 0 1
run_case "reply-zero-remaining" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 0 10240 10240" 1 0 1
run_case "reply-oversized-remaining" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 99999999 10240 10240" 1 0 1
run_case "reply-oversized-rate" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 9999999 10240" 1 0 1
run_case "reply-bad-evict-mac" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240 EVICT bogus" 1 0 1
run_case "reply-wrong-fifth" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240 EXTRA x" 1 0 1
run_case "reply-five-fields" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240 extra" 1 0 1

# --- secondary-method gate (action values as rewritten by binauth_log.sh:
# ndsctl_auth arrives as "auth"; deauth variants arrive ending in "deauth").
# Positional slots beyond $2/$custom are unreliable here; the script must use
# neutral metadata (strict-or-empty MAC, empty ip/token).
run_case "auth-valid" auth AA:BB:CC:DD:EE:01 1789264044 1789350444 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 0 360 1
run_case "auth-unknown" auth AA:BB:CC:DD:EE:01 1789264044 1789350444 \
	"voucher=NOPE-1234" "DENY unknown" 1 0 1
run_case "auth-no-custom" auth AA:BB:CC:DD:EE:01 1789264044 1789350444 \
	"" "" 0 0 0
run_case "auth-malformed-voucher" auth AA:BB:CC:DD:EE:01 1789264044 1789350444 \
	"voucher=A;B" "" 1 0 0
run_case "client_auth-valid" client_auth AA:BB:CC:DD:EE:01 x y \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 0 360 1
run_case "timeout_deauth-passthrough" timeout_deauth AA:BB:CC:DD:EE:01 x y \
	"voucher=TEST-6H" "" 0 0 0
run_case "shutdown_deauth-passthrough" shutdown_deauth AA:BB:CC:DD:EE:01 x y \
	"voucher=TEST-6H" "" 0 0 0

# --- strict ip/token vectors (pre-network rejects: calls must stay 0) ---
run_case "bad-ip-octet" auth_client AA:BB:CC:DD:EE:01 10.0.0.999 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "bad-ip-inject" auth_client AA:BB:CC:DD:EE:01 '10.0.0.1&evil=1' tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "bad-ip-short" auth_client AA:BB:CC:DD:EE:01 10.0.0 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "bad-token-amp" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 'ab&cd' \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "bad-token-eq" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 'ab=cd' \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "bad-token-pct" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 'ab%cd' \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "bad-token-empty" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 '' \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
LONGTOK=$(head -c 129 /dev/zero | tr '\0' 'a')
run_case "bad-token-long" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 "$LONGTOK" \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 1 0 0
run_case "ok-token-punct" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 'tok-1_2.3:4' \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 0 360 1

# --- non-strict MAC degrades to empty metadata, claim still proceeds ---
run_case "loose-mac-emptied" auth_client AABBCCDDEEFF 10.0.0.200 tok1 \
	"voucher=TEST-6H" "ALLOW 21600 10240 10240" 0 360 1

# evict hook: different old MAC must be passed to daemon_deauth exactly once
: > "$EVICT_FILE"
printf '%s' "ALLOW 18000 10240 10240 EVICT AA:BB:CC:DD:EE:09" > "$RESPFILE"
(
	action="auth_client"
	custom=$(b64 "voucher=TEST-6H")
	session_length=0; upload_rate=0; download_rate=0
	upload_quota=0; download_quota=0; exitlevel=0
	set -- auth_client AA:BB:CC:DD:EE:02 redir ua 10.0.0.201 tok2 "$custom"
	. "$PWD/custombinauth.voucher.sh"
	echo "$exitlevel|$session_length"
) > /tmp/cb_out.txt
sleep 1
if grep -q "daemon_deauth AA:BB:CC:DD:EE:09" "$EVICT_FILE" 2>/dev/null \
	&& [ "$(cat /tmp/cb_out.txt)" = "0|300" ]; then
	PASS=$((PASS + 1)); echo "PASS: evict-hook (deauth old MAC, sess=300)"
else
	FAIL=$((FAIL + 1)); echo "FAIL: evict-hook out=[$(cat /tmp/cb_out.txt)] evict=[$(cat "$EVICT_FILE" 2>/dev/null)]"
fi

# neutral path with a stranger-owned binding must ABSTAIN (defaults kept,
# no evict hook), never move it: only auth_client may rebind.
: > "$EVICT_FILE"
printf '%s' "ALLOW 18000 10240 10240 EVICT AA:BB:CC:DD:EE:09" > "$RESPFILE"
(
	action="auth"
	custom=$(b64 "voucher=TEST-6H")
	session_length=0; upload_rate=0; download_rate=0
	upload_quota=0; download_quota=0; exitlevel=0
	set -- auth AA:BB:CC:DD:EE:02 redir ua 10.0.0.201 tok2 "$custom"
	. "$PWD/custombinauth.voucher.sh"
	echo "$exitlevel|$session_length"
) > /tmp/cb_out.txt
sleep 1
if [ "$(cat /tmp/cb_out.txt)" = "0|0" ] && [ ! -s "$EVICT_FILE" ]; then
	PASS=$((PASS + 1)); echo "PASS: neutral-evict-abstain (defaults kept, hook silent)"
else
	FAIL=$((FAIL + 1)); echo "FAIL: neutral-evict-abstain out=[$(cat /tmp/cb_out.txt)] evict=[$(cat "$EVICT_FILE" 2>/dev/null)]"
fi

# --- codeless resume marker (custom decodes to exactly "resume") ---
run_case "resume-allow" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"resume" "ALLOW 18000 10240 10240" 0 300 1
run_case "resume-deny-nomatch" auth_client AA:BB:CC:DD:EE:99 10.0.0.209 tok9 \
	"resume" "DENY nomatch" 1 0 1
run_case "resume-smuggle-eq-denied" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"resume=1" "ALLOW 18000 10240 10240" 1 0 0
run_case "resume-smuggle-suffix-denied" auth_client AA:BB:CC:DD:EE:01 10.0.0.200 tok1 \
	"resumeX" "ALLOW 18000 10240 10240" 1 0 0
run_case "resume-secondary-allow" auth AA:BB:CC:DD:EE:01 1789264044 1789350444 \
	"resume" "ALLOW 18000 10240 10240" 0 300 1
run_case "resume-secondary-deny" auth AA:BB:CC:DD:EE:01 1789264044 1789350444 \
	"resume" "DENY expired" 1 0 1
run_case "resume-deauth-passthrough" client_deauth AA:BB:CC:DD:EE:01 x y \
	"resume" "" 0 0
(
	name="resume-posts-to-resume-endpoint-no-voucher"
	URLFILE=$(mktemp); export URLFILE
	printf '%s' "ALLOW 18000 10240 10240" > "$RESPFILE"
	(
		action="auth_client"
		custom=$(b64 "resume")
		session_length=0; upload_rate=0; download_rate=0
		upload_quota=0; download_quota=0; exitlevel=0
		set -- auth_client AA:BB:CC:DD:EE:01 redir ua 10.0.0.200 tok1 "$custom"
		. "$PWD/custombinauth.voucher.sh"
		echo "$exitlevel|$session_length"
	) > /tmp/cb_out.txt
	if [ "$(cat /tmp/cb_out.txt)" = "0|300" ] \
		&& grep -q "/resume" "$URLFILE" \
		&& grep -q "mac=AA:BB:CC:DD:EE:01" "$URLFILE" \
		&& ! grep -q "voucher=" "$URLFILE"; then
		PASS=$((PASS + 1)); echo "PASS: $name"
	else
		FAIL=$((FAIL + 1)); echo "FAIL: $name out=[$(cat /tmp/cb_out.txt)] url=[$(cat "$URLFILE")]"
	fi
	rm -f "$URLFILE"; unset URLFILE
)

# unconfigured API URL must fail closed
(
	VOUCHER_API_URL=""
	action="auth_client"
	custom=$(b64 "voucher=TEST-6H")
	session_length=0; upload_rate=0; download_rate=0
	upload_quota=0; download_quota=0; exitlevel=0
	set -- auth_client AA:BB:CC:DD:EE:01 redir ua 10.0.0.200 tok1 "$custom"
	. "$PWD/custombinauth.voucher.sh"
	echo "$exitlevel"
) > /tmp/cb_out.txt
if [ "$(cat /tmp/cb_out.txt)" = "1" ]; then
	PASS=$((PASS + 1)); echo "PASS: no-api-url-fail-closed"
else
	FAIL=$((FAIL + 1)); echo "FAIL: no-api-url got=[$(cat /tmp/cb_out.txt)]"
fi

rm -f "$PSKFILE" "$EVICT_FILE" "$CALLFILE" "$RESPFILE" /tmp/cb_out.txt "$HOOK"
rmdir "$STUBBIN" 2>/dev/null
echo "---- custombinauth: PASS=$PASS FAIL=$FAIL ----"
[ "$FAIL" -eq 0 ]
