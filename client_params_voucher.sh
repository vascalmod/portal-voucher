#!/bin/sh
# client_params_voucher.sh — unified portal entry for status.client
#
# Fork of stock client_params.sh (openNDS 10.3.1): same MHD calling
# convention, same helpers, same busy behavior. Changed branches:
#   - `status` unauthenticated/preauth/expired/unknown -> automatic forward
#     into the standard login flow (zero clicks, browser-friendly);
#   - `status` authenticated + live session -> custom status UI (CONNECTED +
#     backend-authoritative remaining + own code + client IP/MAC + Pause +
#     Logout);
#   - ?action=pause on an authenticated self -> ndsctl deauth (self only:
#     identity is server-side $mac from json, never the query) + synchronous
#     backend /pause freeze + PAUSED view (frozen remaining, client IP/MAC,
#     codeless Resume via the ThemeSpec resume flow);
#   - `status` preauth with a paused voucher for this device -> PAUSED view
#     (codeless Resume button, never a code field); anything else preauth ->
#     login forward.
#   - `err511` (captive entry for browsers AND CPD probes) -> paused voucher
#     lookup by client MAC first (FAS query, else the daemon's own client
#     record for direct gateway visits that carry an empty query), otherwise
#     the same automatic forward; HTTP
#     511 + daemon redirect semantics untouched (MHD-owned), so CPD clients
#     are unaffected.
# Display + self-pause only: no firewall, no grant capability. The sole grant
# path stays ThemeSpec -> auth_log -> BinAuth -> backend (see theme_voucher.sh
# and custombinauth.voucher.sh). The one state-changing verb here (pause
# deauth) targets the server-side client only and is recorded idempotently.
#
status=$1
clientip=$2
b64query=$3
OPENNDS_LIBOPENNDS="${OPENNDS_LIBOPENNDS:-/usr/lib/opennds/libopennds.sh}"

do_ndsctl () {
	local timeout=4

	for tic in $(seq $timeout); do
		ndsstatus="ready"
		ndsctlout=$(eval ndsctl "$ndsctlcmd")

		for keyword in $ndsctlout; do

			if [ $keyword = "locked" ]; then
				ndsstatus="busy"
				sleep 1
				break
			fi
		done

		if [ "$ndsstatus" = "ready" ]; then
			break
		fi
	done
}

get_client_zone () {
	# Gets the client zone, (if we don't already have it) ie the connection the client is using, such as:
	# local interface (br-lan, wlan0, wlan0-1 etc.,
	# or remote mesh node mac address

	failcheck=$(echo "$clientif" | grep "get_client_interface")

	if [ -z $failcheck ]; then
		client_if=$(echo "$clientif" | awk '{printf $1}')
		client_meshnode=$(echo "$clientif" | awk '{printf $2}' | awk -F ':' '{print $1$2$3$4$5$6}')
		local_mesh_if=$(echo "$clientif" | awk '{printf $3}')

		if [ ! -z "$client_meshnode" ]; then
			client_zone="MeshZone: $client_meshnode"
		else
			client_zone="LocalZone: $client_if"
		fi
	else
		client_zone=""
	fi
}

htmlentityencode() {
	entitylist="
		s/\"/\&quot;/g
		s/>/\&gt;/g
		s/</\&lt;/g
		s/%/\&#37;/g
		s/'/\&#39;/g
		s/\`/\&#96;/g
	"
	local buffer="$1"

	for entity in $entitylist; do
		entityencoded=$(echo "$buffer" | sed "$entity")
		buffer=$entityencoded
	done

	entityencoded=$(echo "$buffer" | awk '{ gsub(/\$/, "\\&#36;"); print }')
}


parse_variables() {
	# Parse for variables in $query from the list in $queryvarlist:

	for var in $queryvarlist; do
		evalstr=$(echo "$query" | awk -F"$var=" '{print $2}' | awk -F', ' '{print $1}')
		evalstr=$(printf '%s' "$evalstr" | sed 's/%/\\x/g')
		evalstr=$(printf "$evalstr")

		# sanitise $evalstr to prevent code injection
		htmlentityencode "$evalstr"
		evalstr=$entityencoded

		if [ -z "$evalstr" ]; then
			continue
		fi

		eval $var=$(echo "\"$evalstr\"")
		evalstr=""
	done
	query=""
}

parse_parameters() {

	if [ "$status" = "status" ]; then
		ndsctlcmd="json $clientip"
		do_ndsctl

		if [ "$ndsstatus" = "ready" ]; then
			param_str=$ndsctlout

			for param in gatewayname gatewayaddress gatewayfqdn mac version ip client_type clientif session_start session_end \
				last_active token state custom upload_rate_limit_threshold download_rate_limit_threshold \
				upload_packet_rate upload_bucket_size download_packet_rate download_bucket_size \
				upload_quota download_quota upload_this_session download_this_session upload_session_avg download_session_avg
			do
				val=$(echo "$param_str" | grep "\"$param\":" | awk -F'"' '{printf "%s", $4}')

				if [ "$val" = "null" ]; then
					val="Unlimited"
				fi

				if [ -z "$val" ]; then
					eval $param=$(echo "Unavailable")
				else
					eval $param=$(echo "\"$val\"")
				fi
			done

			# url decode and html entity encode gatewayname
			gatewayname_dec=$(printf "${gatewayname//%/\\x}")
			htmlentityencode "$gatewayname_dec"
			gatewaynamehtml=$entityencoded

			# Get client_zone from clientif
			get_client_zone

			# Get human readable times:
			sessionstart=$(date -d @$session_start)

			if [ "$session_end" = "Unlimited" ]; then
				sessionend=$session_end
			else
				sessionend=$(date -d @$session_end)
			fi

			lastactive=$(date -d @$last_active)
		fi
	else
		mountpoint=$("$OPENNDS_LIBOPENNDS" tmpfs)
		. $mountpoint/ndscids/ndsinfo
	fi
}

header() {
# Define a common header html for every page served
	header="<!DOCTYPE html>
		<html>
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<link rel=\"shortcut icon\" href=\"$url/$imagepath\" type=\"image/x-icon\">
		<link rel=\"stylesheet\" type=\"text/css\" href=\"$url/splash.css\">
		<title>$gatewaynamehtml Client Session Status</title>
		</head>
		<body>
		<div class=\"offset\">
		<big-red>
			Session Status<br>
		</big-red>
		<med-blue>
			$gatewaynamehtml
		</med-blue><br>
		<div class=\"insert\" style=\"max-width:100%;\">
	"
	echo "$header"
}

footer() {
	# Define a common footer html for every page served
	year=$(date +'%Y')
	echo "
		<hr>
		<div style=\"font-size:0.5em;\">
			<br>
			<img style=\"height:60px; float:left;\" src=\"$url/$imagepath\" alt=\"Splash Page: For access to the Internet.\">
			&copy; Portal: BlueWave Projects and Services 2015 - $year<br>
			<br>
			Portal Version: $version
			<br><br><br><br>
		</div>
		</div>
		</div>
		</body>
		</html>
	"
}

body() {
	if [ "$ndsstatus" = "busy" ]; then
		pagebody="
			<hr>
			<b>The Portal is busy, please click or tap \"Refresh\"<br><br></b>
			<form>
				<input type=\"button\" VALUE=\"Refresh\" onClick=\"history.go(0);return true;\">
			</form>
		"
	else
		exit 1
	fi

	echo "$pagebody"
}

# --- unified-entry additions (status + err511 branches; busy untouched) ---

# voucher_session_active: true (0) only for a live voucher session:# Authenticated state AND (Unlimited end OR numeric end in the future).
# Anything else (preauth, unknown, expired, unparseable) -> login-forward.
# Sets vrem (seconds remaining) when numeric, else empty.
voucher_session_active() {
	vrem=""
	[ "$state" = "Authenticated" ] || return 1
	case "$session_end" in
		Unlimited)
			return 0
			;;
	esac
	case "$session_end" in
		""|*[!0-9]*)
			return 1
			;;
	esac
	vnow=$(date +%s)
	vrem=$((session_end - vnow))
	vnow=""
	[ "$vrem" -gt 0 ]
}

# voucher_code: decode the ndsctl custom field (b64 "voucher=CODE" as set by
# the ThemeSpec) to the display code, "RESUMED" for the exact codeless-resume
# marker (b64 "resume": granted without a code, so there is nothing to show
# but the session is genuinely voucher-backed), or "-" when absent/invalid.
# Strict allowlist mirrors the rest of the system; nothing unvalidated is
# reflected. Callers map RESUMED to display text; the sentinel never reaches
# the backend.
voucher_code() {
	vcode="-"
	case "$custom" in
		""|Unavailable|Unlimited)
			;;
		*)
			vraw=$(ndsctl b64decode "$custom" 2>/dev/null | tr -d '\r\n')
			case "$vraw" in
				resume)
					vcode="RESUMED"
					;;
				voucher=*)
					vcode=${vraw#voucher=}
					vlen=${#vcode}
					if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
						vcode="-"
					else
						case "$vcode" in
							*[!A-Z0-9-]*)
								vcode="-"
								;;
						esac
					fi
					vlen=""
					;;
			esac
			vraw=""
			;;
	esac
	printf '%s' "$vcode"
	vcode=""
}

# Backend reads for status display and pause (best-effort; empty/unknown on
# any failure so views degrade instead of breaking). Secrets live only in
# POST bodies on the LAN; never in URLs, logs, or pages. Config mirrors the
# claimant (env first, UCI fallback, PSK file); without it, backend features
# quietly stay off and daemon numbers are used.
vapi_init() {
	VAPI_BASE=""
	VAPI_PSK=""
	vapi_url="${VOUCHER_API_URL:-}"
	if [ -z "$vapi_url" ] && command -v uci >/dev/null 2>&1; then
		vapi_url=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
	fi
	case "$vapi_url" in
		*/claim)
			VAPI_BASE=${vapi_url%/claim}
			;;
		*)
			vapi_url=""
			return 0
			;;
	esac
	vapi_url=""
	vpskfile="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
	if [ -f "$vpskfile" ]; then
		VAPI_PSK=$(cat "$vpskfile" 2>/dev/null)
	fi
	vpskfile=""
}

# vapi_post <path> <fields-without-psk> -> stdout body or empty. Always rc 0.
# Callers pass only pre-sanitized values (strict MAC or empty here).
vapi_post() {
	[ -n "$VAPI_BASE" ] && [ -n "$VAPI_PSK" ] || return 0
	vbody="$2&psk=$VAPI_PSK"
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T 3 -O - --post-data="$vbody" "$VAPI_BASE$1" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 3 -O - --post-data="$vbody" "$VAPI_BASE$1" 2>/dev/null
	fi
	vbody=""
}

# vbackend_session: paused/active display state for server-side $mac.
# Sets vb_state (active|paused|none) + vb_remaining (digits or empty).
# Backend is authoritative; daemon numbers are only a display fallback.
vbackend_session() {
	vb_state="none"
	vb_remaining=""
	vbmac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
	case "$vbmac" in
		??:??:??:??:??:??)
			case "$vbmac" in
				*[!0-9A-F:]*)
					vbmac=""
					;;
			esac
			;;
		*)
			vbmac=""
			;;
	esac
	[ -z "$vbmac" ] && return 0
	vresp=$(vapi_post "/session" "mac=$vbmac")
	vbmac=""
	[ -z "$vresp" ] && return 0
	case "$vresp" in
		*'"paused": true'*)
			vb_state="paused"
			;;
		*'"active": true'*)
			vb_state="active"
			;;
		*)
			vresp=""
			return 0
			;;
	esac
	vb_remaining=$(printf '%s' "$vresp" | grep -o '"remaining_seconds": [0-9]*' | awk '{print $2}')
	vresp=""
	case "$vb_remaining" in
		""|*[!0-9]*)
			vb_remaining=""
			vb_state="none"
			;;
	esac
}

# voucher_forward_page: unauthenticated browsers go straight into the standard
# login flow with zero clicks. Paint FIRST, navigate SECOND: the loading state
# below renders immediately (spinner + text), and navigation fires on window
# load — a head-parse script could navigate before first paint, leaving a
# blank (black in dark mode) gap during the multi-second login render.
# Meta-refresh survives underneath for no-JS clients; no manual button by
# owner decision (CPD ignores page bodies entirely). The target is the stock
# fresh FAS query for the ThemeSpec — no voucher data is fabricated here.
# CPD clients ignore page bodies (protocol is MHD's 511 + redirect), so this
# changes nothing for them.
voucher_forward_page() {
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<meta http-equiv=\"refresh\" content=\"0;url=$url/login\">
		<meta name=\"color-scheme\" content=\"light\">
		<title>WI-FI E-VOUCHER</title>
		<link rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,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\">
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		body { min-height: 100vh; font-family: Arial, Helvetica, sans-serif; background: #f4f6f8; color: #17202a; display: flex; align-items: center; justify-content: center; padding: 20px; }
		.container { width: 100%; max-width: 420px; }
		.card { background: #ffffff; border: 1px solid #e5e9ed; border-radius: 18px; padding: 30px 24px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06); text-align: center; }
		.brand-icon { width: 58px; height: 58px; margin: 0 auto 16px; border-radius: 16px; background: #1677ff; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: bold; }
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.brand p { margin-top: 7px; font-size: 12px; color: #7b8794; letter-spacing: 1px; }
		.note { margin-top: 16px; text-align: center; font-size: 11px; color: #7b8794; line-height: 1.5; }
		html { background: #f4f6f8; }
		.load-spinner { width: 34px; height: 34px; margin: 22px auto 6px; border: 3px solid #e5e9ed; border-top-color: #1677ff; border-radius: 50%; animation: vspin 0.8s linear infinite; }
		@keyframes vspin { to { transform: rotate(360deg); } }
		</style>
		</head>
		<body>
		<main class=\"container\">
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>CREATING SESSION</p>
			</div>
			<div class=\"load-spinner\"></div>
			<p class=\"note\">Preparing your secure login&hellip;</p>
		</section>
		</main>
		<script>window.addEventListener(\"load\",function(){window.location.replace(\"$url/login\");});</script>
		</body>
		</html>
	"
}

# vportal_log <decision>: one structured audit line per portal outcome for
# reconnect diagnosis (spec 21). Fields: client ip/mac (server-side only),
# backend lookup HIT/MISS, voucher state, remaining seconds, final decision
# (SHOW_RESUME/SHOW_LOGIN/SHOW_STATUS). MAC only — the voucher code is never
# logged. Best-effort: silent when logger is absent. Callers invoke it just
# before rendering each branch outcome.
vportal_log() {
	if command -v logger >/dev/null 2>&1; then
		vli="$clientip"
		if [ -z "$vli" ]; then
			vli="-"
		fi
		vlm="$mac"
		if [ -z "$vlm" ]; then
			vlm="-"
		fi
		vls="$vb_state"
		if [ -z "$vls" ]; then
			vls="none"
		fi
		if [ "$vls" = "none" ]; then
			vlh="MISS"
		else
			vlh="HIT"
		fi
		vlr="$vb_remaining"
		if [ -z "$vlr" ]; then
			vlr="-"
		fi
		logger -t opennds-portal "ip=$vli mac=$vlm lookup=$vlh state=$vls remaining=$vlr decision=$1" 2>/dev/null
		vli=""
		vlm=""
		vls=""
		vlh=""
		vlr=""
	fi
}

# vdisp_band: which WiFi band the client is associated on ("2.4 GHz" / "5 GHz"
# / "6 GHz", else an em-dash). Method: list wireless interfaces via iw, find
# the one holding a station entry for the validated $vdisp_mac, read that
# interface's channel frequency, map by range. Fully dynamic (no hardcoded
# interface names — this AP serves one SSID on phy1-ap0/2.4G + phy0-ap0/5G
# today, but names may change). Display-only: only digits from iw output are
# ever parsed, the MAC is the strict-validated form, interfaces come from the
# local iw listing (never client input). Best-effort: any failure (no iw,
# client gone, unparsable) yields the dash without breaking the page.
vdisp_band() {
	VBAND="—"
	case "$vdisp_mac" in
		??:??:??:??:??:??)
			;;
		*)
			return 0
			;;
	esac
	if ! command -v iw >/dev/null 2>&1; then
		return 0
	fi
	vifs=$(iw dev 2>/dev/null | awk '/Interface/ {print $2}')
	if [ -z "$vifs" ]; then
		vifs="phy0-ap0 phy1-ap0"
	fi
	for vif in $vifs; do
		case "$vif" in
			""|*[!A-Za-z0-9_.-]*)
				continue
				;;
		esac
		if iw dev "$vif" station get "$vdisp_mac" 2>/dev/null | grep -q "^Station "; then
			# Frequency sits in parentheses: "channel 36 (5180 MHz)". The
			# width suffix ("width: 80 MHz") must NOT match, so anchor on
			# the parens first, then take its digits.
			vmhz=$(iw dev "$vif" info 2>/dev/null | grep -i "channel" | grep -o "([0-9][0-9]* MHz)" | head -n 1 | grep -o "[0-9][0-9]*" | head -n 1)
			case "$vmhz" in
				""|*[!0-9]*)
					;;
				*)
					if [ "$vmhz" -lt 3000 ] 2>/dev/null; then
						VBAND="2.4 GHz"
					elif [ "$vmhz" -gt 5925 ] 2>/dev/null; then
						VBAND="6 GHz"
					elif [ "$vmhz" -gt 4000 ] 2>/dev/null; then
						VBAND="5 GHz"
					fi
					;;
			esac
			break
		fi
	done
	vifs=""
	vif=""
	vmhz=""
}

# vdisp_net: display-safe IP/MAC from server-side values only ($mac/$ip from
# ndsctl json, falling back to $clientmac/$clientip from the daemon query).
# Strict-or-blank so nothing unvalidated is reflected; MAC shown uppercase.
vdisp_net() {
	vdisp_mac="$mac"
	if [ -z "$vdisp_mac" ]; then
		vdisp_mac="$clientmac"
	fi
	vdisp_mac=$(printf '%s' "$vdisp_mac" | tr 'a-z' 'A-Z')
	case "$vdisp_mac" in
		??:??:??:??:??:??)
			case "$vdisp_mac" in
				*[!0-9A-F:]*)
					vdisp_mac="-"
					;;
			esac
			;;
		*)
			vdisp_mac="-"
			;;
	esac
	vdisp_ip="$ip"
	if [ -z "$vdisp_ip" ]; then
		vdisp_ip="$clientip"
	fi
	case "$vdisp_ip" in
		*.*.*.*)
			case "$vdisp_ip" in
				*[!0-9.]*)
					vdisp_ip="-"
					;;
			esac
			;;
		*)
			vdisp_ip="-"
			;;
	esac
}

# voucher_submit_js: busy-state for portal action buttons (Pause/Logout/
# Resume). Twin of the ThemeSpec voucherSubmit: on submit, shows the inline
# spinner, relabels from the button's data-busy attribute, and disables
# against double taps; pageshow restores (back-navigation). Progressive
# enhancement ONLY — inert where JS is blocked, and correctness never depends
# on it (pause/resume/logout are all idempotent server-side). ES5 syntax.
voucher_submit_js() {
	echo "<script>(function(){function arm(f){var b=f.querySelector('button[type=submit]');if(!b){return true;}if(b.disabled){return false;}var t=b.querySelector('.btn-text');if(t){b.setAttribute('data-label',t.textContent);var bl=b.getAttribute('data-busy');if(bl){t.textContent=bl;}}b.classList.add('busy');b.disabled=true;return true;}window.voucherSubmit=function(f){return arm(f);};window.addEventListener('pageshow',function(){var bs=document.querySelectorAll('button.busy');for(var i=0;i<bs.length;i++){var b=bs[i];b.disabled=false;b.classList.remove('busy');var t=b.querySelector('.btn-text');if(t&&b.hasAttribute('data-label')){t.textContent=b.getAttribute('data-label');}}});})();</script>"
}

# Live countdown snippet (progressive enhancement ONLY): ticks the sibling
# .timer[data-remaining] once per second from a frozen deadline, so background
# throttling self-corrects and no client clock is trusted. Where JS is blocked
# the static server-rendered text remains. ES5 syntax for old webviews.
# Twin in theme_voucher.sh.
voucher_countdown_js() {
	echo "<script>(function(){var el=document.querySelector('.timer[data-remaining]');if(!el){return;}var rem=parseInt(el.getAttribute('data-remaining'),10);if(isNaN(rem)||rem<0){rem=0;}var end=Date.now()+rem*1000;function pad(n){n=Math.floor(n);return (n<10?'0':'')+n;}function tick(){var s=Math.max(0,Math.round((end-Date.now())/1000));el.textContent=pad(s/3600)+':'+pad((s%3600)/60)+':'+pad(s%60);if(s<=0){clearInterval(iv);}}var iv=setInterval(tick,1000);tick();})();</script>"
}

# voucher_status_page: authenticated voucher session status (self-contained,
# no external CSS/images). Timer omitted when the end is Unlimited rather
# than fabricating one. No account dump, no stock Session Status text.
voucher_status_page() {
	if [ -n "$vrem" ]; then
		# $vrem is digit-guarded by voucher_session_active: safe to embed.
		vremsecs="$vrem"
		vtimer=$(printf "%02d:%02d:%02d" $((vrem/3600)) $(((vrem%3600)/60)) $((vrem%60)))
		vjsct=$(voucher_countdown_js)
		vtimerblock="
			<div class=\"timer-section\">
				<span class=\"timer-label\">REMAINING</span>
				<div class=\"timer\" data-remaining=\"$vremsecs\">$vtimer</div>
				$vjsct
			</div>
		"
	else
		vtimerblock=""
	fi
	vtimer=""
	vremsecs=""
	vjsct=""
	vcode=$(voucher_code)
	if [ "$vcode" = "RESUMED" ]; then
		vcode="Resumed session"
	fi
	vdisp_net
	vdisp_band
	vsubmitjs=$(voucher_submit_js)
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<title>WI-FI E-VOUCHER</title>
		<link rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,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\">
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		body { min-height: 100vh; font-family: Arial, Helvetica, sans-serif; background: #f4f6f8; color: #17202a; display: flex; align-items: center; justify-content: center; padding: 20px; }
		.container { width: 100%; max-width: 420px; }
		.card { background: #ffffff; border: 1px solid #e5e9ed; border-radius: 18px; padding: 30px 24px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06); }
		.brand { text-align: center; margin-bottom: 30px; }
		.brand-icon { width: 58px; height: 58px; margin: 0 auto 16px; border-radius: 16px; background: #1677ff; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: bold; }
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.connection-status { display: inline-flex; align-items: center; gap: 7px; margin-top: 12px; padding: 7px 11px; border-radius: 20px; background: #eaf8ef; color: #16a34a; font-size: 11px; font-weight: bold; }
		.status-dot { width: 7px; height: 7px; border-radius: 50%; background: #16a34a; }
		.timer-section { text-align: center; padding: 24px 0; border-top: 1px solid #e5e9ed; border-bottom: 1px solid #e5e9ed; }
		.timer-label { display: block; color: #7b8794; font-size: 11px; font-weight: bold; letter-spacing: 1px; }
		.timer { margin-top: 8px; font-size: 38px; font-weight: 700; letter-spacing: 2px; font-variant-numeric: tabular-nums; }
		.voucher-info { padding: 8px 0; }
		.info-row { display: flex; justify-content: space-between; align-items: center; padding: 14px 0; border-bottom: 1px solid #e5e9ed; font-size: 13px; }
		.info-row:last-child { border-bottom: 0; }
		.info-row span { color: #7b8794; }
		.active-text { color: #16a34a; }
		.paused-status { display: inline-flex; align-items: center; gap: 7px; margin-top: 12px; padding: 7px 11px; border-radius: 20px; background: #fef3e2; color: #b45309; font-size: 11px; font-weight: bold; }
		.paused-dot { width: 7px; height: 7px; border-radius: 50%; background: #b45309; }
		.paused-text { color: #b45309; }
		.logout-form button { width: 100%; height: 50px; margin-top: 14px; border: 0; border-radius: 10px; background: #17202a; color: #ffffff; font-size: 14px; font-weight: bold; cursor: pointer; }
		.pause-form button { width: 100%; height: 50px; margin-top: 14px; border: 0; border-radius: 10px; background: #1677ff; color: #ffffff; font-size: 14px; font-weight: bold; cursor: pointer; }
		.pause-form button:disabled, .logout-form button:disabled { opacity: 0.65; cursor: not-allowed; }
		.btn-spinner { display: none; width: 14px; height: 14px; margin-right: 8px; border: 2px solid rgba(255, 255, 255, 0.45); border-top-color: #ffffff; border-radius: 50%; vertical-align: -3px; animation: vspin 0.8s linear infinite; }
		button.busy .btn-spinner { display: inline-block; }
		@keyframes vspin { to { transform: rotate(360deg); } }
		.hint { margin-top: 13px; text-align: center; color: #7b8794; font-size: 11px; line-height: 1.5; }
		@media (max-width: 400px) {
			body { padding: 12px; }
			.card { padding: 25px 18px; border-radius: 15px; }
			.timer { font-size: 32px; }
		}
		</style>
		</head>
		<body>
		<main class=\"container\">
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<div class=\"connection-status\">
					<span class=\"status-dot\"></span>
					CONNECTED
				</div>
			</div>
			$vtimerblock
			<div class=\"voucher-info\">
				<div class=\"info-row\">
					<span>Voucher</span>
					<strong>$vcode</strong>
				</div>
				<div class=\"info-row\">
					<span>IP</span>
					<strong>$vdisp_ip</strong>
				</div>
				<div class=\"info-row\">
					<span>MAC</span>
					<strong>$vdisp_mac</strong>
				</div>
				<div class=\"info-row\">
					<span>Band</span>
					<strong>$VBAND</strong>
				</div>
				<div class=\"info-row\">
					<span>Speed</span>
					<strong>10 Mbps</strong>
				</div>
				<div class=\"info-row\">
					<span>Status</span>
					<strong class=\"active-text\">Active</strong>
				</div>
			</div>
			<form class=\"pause-form\" action=\"$url/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<input type=\"hidden\" name=\"action\" value=\"pause\">
				<button type=\"submit\" data-busy=\"PAUSING…\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">Pause</span></button>
			</form>
			<form class=\"logout-form\" action=\"$url/opennds_deny/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<button type=\"submit\" data-busy=\"LOGGING OUT…\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">Logout</span></button>
			</form>
			$vsubmitjs
			<p class="hint">
				Your connection is active. Pause freezes your remaining time.
			</p>
		</section>
		</main>
		</body>
		</html>
	"
	vtimerblock=""
	vcode=""
	vrem=""
	vdisp_ip=""
	vdisp_mac=""
	VBAND=""
	vsubmitjs=""
}

# voucher_paused_page: frozen-time display + resume path. Uses $vb_remaining
# (digits or empty, from vbackend_session). The remaining time renders as
# STATIC text deliberately: time is frozen while paused, so there is nothing
# to tick (no countdown attribute/script). No voucher row and no code field:
# the MAC lookup never reveals the code, and Resume needs none — it carries
# resume=1 into the stock login endpoint (fresh FAS query), where the
# ThemeSpec resume flow re-verifies the server-side MAC against the backend
# before any grant. Client IP/MAC shown for the holder's own reference.
voucher_paused_page() {
	if [ -n "$vb_remaining" ]; then
		vptimer=$(printf "%02d:%02d:%02d" $((vb_remaining/3600)) $(((vb_remaining%3600)/60)) $((vb_remaining%60)))
		vptimerblock="
			<div class=\"timer-section\">
				<span class=\"timer-label\">REMAINING</span>
				<div class=\"timer\">$vptimer</div>
			</div>
		"
	else
		vptimerblock=""
	fi
	vptimer=""
	vdisp_net
	vdisp_band
	vsubmitjs=$(voucher_submit_js)
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<title>WI-FI E-VOUCHER</title>
		<link rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,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\">
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		body { min-height: 100vh; font-family: Arial, Helvetica, sans-serif; background: #f4f6f8; color: #17202a; display: flex; align-items: center; justify-content: center; padding: 20px; }
		.container { width: 100%; max-width: 420px; }
		.card { background: #ffffff; border: 1px solid #e5e9ed; border-radius: 18px; padding: 30px 24px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06); }
		.brand { text-align: center; margin-bottom: 30px; }
		.brand-icon { width: 58px; height: 58px; margin: 0 auto 16px; border-radius: 16px; background: #1677ff; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: bold; }
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.paused-status { display: inline-flex; align-items: center; gap: 7px; margin-top: 12px; padding: 7px 11px; border-radius: 20px; background: #fef3e2; color: #b45309; font-size: 11px; font-weight: bold; }
		.paused-dot { width: 7px; height: 7px; border-radius: 50%; background: #b45309; }
		.timer-section { text-align: center; padding: 24px 0; border-top: 1px solid #e5e9ed; border-bottom: 1px solid #e5e9ed; }
		.timer-label { display: block; color: #7b8794; font-size: 11px; font-weight: bold; letter-spacing: 1px; }
		.timer { margin-top: 8px; font-size: 38px; font-weight: 700; letter-spacing: 2px; font-variant-numeric: tabular-nums; }
		.voucher-info { padding: 8px 0; }
		.info-row { display: flex; justify-content: space-between; align-items: center; padding: 14px 0; border-bottom: 1px solid #e5e9ed; font-size: 13px; }
		.info-row:last-child { border-bottom: 0; }
		.info-row span { color: #7b8794; }
		.paused-text { color: #b45309; }
		.resume-form button { width: 100%; height: 50px; margin-top: 14px; border: 0; border-radius: 10px; background: #1677ff; color: #ffffff; font-size: 14px; font-weight: bold; cursor: pointer; }
		.resume-form button:disabled { opacity: 0.65; cursor: not-allowed; }
		.btn-spinner { display: none; width: 14px; height: 14px; margin-right: 8px; border: 2px solid rgba(255, 255, 255, 0.45); border-top-color: #ffffff; border-radius: 50%; vertical-align: -3px; animation: vspin 0.8s linear infinite; }
		button.busy .btn-spinner { display: inline-block; }
		@keyframes vspin { to { transform: rotate(360deg); } }
		.hint { margin-top: 13px; text-align: center; color: #7b8794; font-size: 11px; line-height: 1.5; }
		@media (max-width: 400px) {
			body { padding: 12px; }
			.card { padding: 25px 18px; border-radius: 15px; }
			.timer { font-size: 32px; }
		}
		</style>
		</head>
		<body>
		<main class=\"container\">
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<div class=\"paused-status\">
					<span class=\"paused-dot\"></span>
					PAUSED
				</div>
			</div>
			$vptimerblock
			<div class=\"voucher-info\">
				<div class=\"info-row\">
					<span>IP</span>
					<strong>$vdisp_ip</strong>
				</div>
				<div class=\"info-row\">
					<span>MAC</span>
					<strong>$vdisp_mac</strong>
				</div>
				<div class=\"info-row\">
					<span>Band</span>
					<strong>$VBAND</strong>
				</div>
				<div class=\"info-row\">
					<span>Speed</span>
					<strong>10 Mbps</strong>
				</div>
				<div class=\"info-row\">
					<span>Status</span>
					<strong class=\"paused-text\">Paused</strong>
				</div>
			</div>
			<p class=\"hint\">
				Your remaining time is frozen. Press Resume to continue — no voucher code needed.
			</p>
			<form class=\"resume-form\" action=\"$url/login\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<input type=\"hidden\" name=\"resume\" value=\"1\">
				<button type=\"submit\" data-busy=\"RESUMING…\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">Resume</span></button>
			</form>
			$vsubmitjs
		</section>
		</main>
		</body>
		</html>
	"
	vptimerblock=""
	vb_remaining=""
	vdisp_ip=""
	vdisp_mac=""
	VBAND=""
	vsubmitjs=""
}

# Start generating the html:
if [ -z "$clientip" ]; then
	exit 1
fi

# Download remote resources eg. images and html if not already present
# Images and data files are defined in the openNDS config file using fas_custom_images_list and fas_custom_files_list
# This is the same set of resources that are used in ThemeSpec PreAuth scripts.
# Default logo is the openNDS splash image (/etc/opennds/htdocs/images/splash.jpg)
#
# An example logo can be found in the git repository (https://raw.githubusercontent.com/openNDS/openNDS/master/resources/avatar.png)
# In the OpenWrt UCI config file for openNDS, add the line:
# 	list fas_custom_images_list 'logo_png=https://raw.githubusercontent.com/openNDS/openNDS/master/resources/avatar.png'
#
# For more details see:
# https://opennds.readthedocs.io/en/stable/customparams.html
#
# Do the download(s):

# This default status.client page can by example show a custom logo:
"$OPENNDS_LIBOPENNDS" download "/usr/lib/opennds/download_resources.sh" "" "" "0" "" &>/dev/null

if [ -e "/etc/opennds/htdocs/ndsremote/logo.png" ]; then
	imagepath="ndsremote/logo.png"
else
	imagepath="images/splash.jpg"
fi

if [ "$status" = "status" ] || [ "$status" = "err511" ]; then
	parse_parameters

	if [ -z "$gatewayfqdn" ] || [ "$gatewayfqdn" = "disable" ] || [ "$gatewayfqdn" = "disabled" ]; then
		url="http://$gatewayaddress"
	else
		url="http://$gatewayfqdn"
	fi

	querystr=""

		if [ ! -z "$b64query" ]; then
			ndsctlcmd="b64decode $b64query"
			do_ndsctl
			querystr=$ndsctlout	
			# strip off leading "?" character
			querystr=$(printf '%.1024s' "${querystr#?}")
			queryvarlist=""

			for element in $querystr; do
				htmlentityencode "$element"
				element=$entityencoded
				varname=$(echo "$element" | awk -F'=' '$2!="" {printf "%s", $1}')
				queryvarlist="$queryvarlist $varname"
			done

			query=$querystr
			parse_variables
		fi

		# Required before any status lookup or pause POST.  Without this the
		# vapi_post() helper has no endpoint/PSK and silently returns empty.
		vapi_init

		if [ "$status" = "err511" ]; then
			# Captive-portal entry (browsers AND CPD probes): forward straight
			# into the standard login flow unless this MAC already owns a
			# paused voucher. HTTP 511 status + daemon redirect behavior is
			# unchanged (protocol set by MHD, not this body), so CPD clients are
			# unaffected; human browsers skip the extra Continue tap via
			# meta-refresh.
			if [ -z "$mac" ] && [ -n "$clientmac" ]; then
				mac="$clientmac"
			fi
			# Direct gateway visits (and some CPD probes) arrive with an EMPTY
			# FAS query: no clientmac to fall back to, so the lookup below
			# would silently miss and every refresh/reconnect would show the
			# login page instead of the paused RESUME UI. Resolve the MAC
			# server-side from the daemon's own client record (same source
			# the status branch uses). $clientip is MHD-supplied (never
			# browser input), and vbackend_session strict-validates the MAC
			# before any backend lookup.
			if [ -z "$mac" ] && [ -n "$clientip" ]; then
				ndsctlcmd="json $clientip"
				do_ndsctl
				if [ "$ndsstatus" = "ready" ]; then
					mac=$(printf '%s' "$ndsctlout" | grep '"mac":' | awk -F'"' '{printf "%s", $4}')
					case "$mac" in
						""|null|Null|Unavailable)
							mac=""
							;;
					esac
				fi
				ndsctlcmd=""
				ndsctlout=""
			fi
			vbackend_session
			if [ "$vb_state" = "paused" ]; then
				vportal_log SHOW_RESUME
				voucher_paused_page
				exit 0
			fi
			vportal_log SHOW_LOGIN
			vb_state=""
			vb_remaining=""
			voucher_forward_page
			exit 0
		fi

	# status branch: busy keeps the stock busy page; otherwise branch on the
	# live voucher session (never the stock account dump).
	if [ "$ndsstatus" = "busy" ]; then
		header
		body
		footer
		exit 0
	fi

	if voucher_session_active; then
		# PAUSE action: only the daemon-authenticated client itself. Identity
		# is server-side ($mac from json, never the query): like the stock
		# Logout GET form, a client can only ever pause itself.
		if [ "$action" = "pause" ] && [ -n "$mac" ]; then
			if ndsctl deauth "$mac" >/dev/null 2>&1; then
				# Freeze synchronously so the fresh numbers render below.
				# (The BinAuth deauth callback repeats this idempotently.)
				vpmac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
				case "$vpmac" in
					??:??:??:??:??:??)
						case "$vpmac" in
							*[!0-9A-F:]*)
								vpmac=""
								;;
						esac
						;;
					*)
						vpmac=""
						;;
				esac
				vb_remaining=""
				if [ -n "$vpmac" ]; then
					vpresp=$(vapi_post "/pause" "mac=$vpmac")
					case "$vpresp" in
						"PAUSED "*)
							vb_remaining=${vpresp#PAUSED }
							case "$vb_remaining" in
								""|*[!0-9]*)
									vb_remaining=""
									;;
							esac
							;;
					esac
					vpresp=""
				fi
				vpmac=""
				# Do not claim that time is frozen unless the authoritative backend
				# confirmed it. A later BinAuth callback may still complete an
				# idempotent pause, but this request must not render a false PAUSED UI.
				if [ -n "$vb_remaining" ]; then
					vb_state="paused"
					vportal_log SHOW_RESUME
					voucher_paused_page
				else
					vportal_log SHOW_LOGIN
					voucher_forward_page
				fi
				exit 0
			fi
			# Deauth failed: fall through, current (still live) views below.
		fi
		# Backend-first: authoritative remaining; daemon numbers fallback.
		vbackend_session
		if [ "$vb_state" = "paused" ]; then
			vportal_log SHOW_RESUME
			voucher_paused_page
			exit 0
		fi
		if [ "$vb_state" = "active" ] && [ -n "$vb_remaining" ]; then
			vrem="$vb_remaining"
		fi
		vportal_log SHOW_STATUS
		vb_state=""
		vb_remaining=""
		voucher_status_page
		exit 0
	fi

	# Not daemon-authed: device with a paused voucher sees it (codeless
	# Resume button, never a code field), anything else gets the login
	# forward. Backend-ACTIVE here (stale callback race) also forwards:
	# re-login re-syncs authoritatively.
	vbackend_session
	if [ "$vb_state" = "paused" ]; then
		vportal_log SHOW_RESUME
		voucher_paused_page
		exit 0
	fi
	vportal_log SHOW_LOGIN
	vb_state=""
	vb_remaining=""

	voucher_forward_page
	exit 0
else
	exit 1
fi
