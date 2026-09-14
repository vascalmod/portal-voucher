#!/bin/sh
# custombinauth.voucher.sh — Stage 2 real voucher validation + initial session auth
#
# DEPLOY: copy to /usr/lib/opennds/custombinauth.sh (backup the stub first).
#   Sourced by binauth_log.sh AFTER it sets:
#     action, $1..$8 positionals, $custom, session_length/upload_rate/
#     download_rate/upload_quota/download_quota, exitlevel
#   (see opennds/binauth_log.sh:277-298). We may override those six values.
#   Parent echoes them and exits with $exitlevel (300-309).
#
# SCOPE: usage accounting (only ACTIVE time is consumed).
#   - auth_client + other grant-capable methods carrying voucher= : validated
#     via backend claim (see method gate below); ALLOW sets session/rates.
#   - *deauth callbacks: pause-recording POST to backend /pause (idempotent;
#     button path and callback both fire safely). Parent exitlevel/quotas are
#     NEVER assigned here: callbacks cannot grant, by construction.
#   - Fail CLOSED: any attempted-but-failed voucher validation => exitlevel=1.
#     The stock REQUEST FAILED page is generic (no invalid-vs-expired oracle).
#   - Single DB + single validation function live in the backend (Ubuntu +
#     PostgreSQL). This script is a thin EAP-side claimant: it NEVER validates
#     locally, NEVER branches per browser (CPD vs Chrome identical).
#   - MAC/IP/token are transient metadata for the claim, NEVER identity —
#     except on the codeless resume path below, where the server-side MAC is
#     the identity the backend authorizes against. Binding is STRICT
#     backend-side: a voucher bound to one MAC is never moved by a claim from
#     another (backend denies "bound"); secondary methods never disturb a
#     binding that belongs to someone else (abstain instead). A legacy EVICT
#     field in a backend reply is still parsed strictly and deauthed
#     best-effort via the documented libopennds daemon hook (meant to be
#     called from binauth scripts).
#   - CODELESS RESUME: when custom decodes to exactly "resume" (set only by
#     the ThemeSpec resume flow after its own backend pre-check), the MAC from
#     the server-side BinAuth positionals IS the identity: we POST the
#     /resume endpoint (sibling of the claim URL) with that MAC and grant only
#     on its ALLOW line. No voucher value exists anywhere on this path, and a
#     client-controlled string can never trigger it except through the exact
#     marker — which alone grants nothing without the backend's MAC-bound
#     decision.
#
# PRIVACY: voucher/custom never echoed to pages (ThemeSpec rule). Here the
#   value only travels EAP->backend in the claim POST body. Local syslog (if
#   any) carries a MASKED voucher fingerprint only, never the PSK.
#
# SAFETY: plain assignments only. No eval, no backticks, no unquoted
#   expansions of client data, no client data inside awk/sed programs.
#   Inside BinAuth only `ndsctl b64encode/b64decode` may be used
#   (binauth_log.sh:170-174); all other openNDS calls go through the async
#   libopennds daemon hooks, best-effort, never fatal.
#
# Config (EAP-local, set via environment or UCI; NOT in this repo):
#   VOUCHER_API_URL   full claim URL, e.g. https://voucher.lan/claim
#                     (empty/unset => deny; fail-closed forces configuration)
#   VOUCHER_PSK_FILE  file holding the API PSK, mode 0600 (default below)
#   VOUCHER_TIMEOUT   seconds per claim attempt (default 5, one attempt only)
#   VOUCHER_UCI_URL / VOUCHER_UCI_PSKFILE: optional UCI option names (defaults below)

# --- defaults (no secrets here) ---
VOUCHER_API_URL="${VOUCHER_API_URL:-}"
VOUCHER_PSK_FILE="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
VOUCHER_TIMEOUT="${VOUCHER_TIMEOUT:-5}"
# Hook path override is for local tests only; production is always the path below.
VOUCHER_LIBOPENDS="${VOUCHER_LIBOPENDS:-/usr/lib/opennds/libopennds.sh}"

if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
	VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
fi
if [ ! -f "$VOUCHER_PSK_FILE" ] && command -v uci >/dev/null 2>&1; then
	_uci_pskfile=$(uci get opennds.@opennds[0].voucher_psk_file 2>/dev/null)
	if [ -n "$_uci_pskfile" ]; then
		VOUCHER_PSK_FILE="$_uci_pskfile"
	fi
	_uci_pskfile=""
fi

# --- shared backend claim (used by every validated path below) ---
# Requires prepared globals: vnorm, vmac, vip, vtoken, vneutral (0|1), vmethod,
# vresume (0|1: codeless resume-by-MAC via the /resume endpoint instead of the
# claim URL, with no voucher field in the body and no voucher anywhere else).
# Sets the parent contract vars (session_length, rates, quotas, exitlevel).
# Secondary methods (vneutral=1) confirm-or-deny only: when the backend names
# an EVICT mac owned by someone else, we ABSTAIN with parent defaults instead
# of disturbing the authoritative binding (only auth_client may rebind).
# Never exits; caller falls through to binauth_log.sh tail.
vbackend_claim() {
	# NOTE: caller pre-sets vdeny for gate failures (e.g. bad charset/meta);
	# the guarded stages below skip, and the apply stage enforces the deny.
	# Fresh vdeny state is the caller's responsibility (both callers init it).

	# --- config present? (fail-closed forces operator configuration) ---
	vpsk=""
	if [ -z "$vdeny" ]; then
		if [ -z "$VOUCHER_API_URL" ]; then
			vdeny="no_api_url"
		elif [ ! -f "$VOUCHER_PSK_FILE" ]; then
			vdeny="no_psk_file"
		else
			vpsk=$(cat "$VOUCHER_PSK_FILE" 2>/dev/null)
			if [ -z "$vpsk" ]; then
				vdeny="no_psk"
			fi
		fi
	fi

	# --- claim against backend (router egress; browser never calls it) ---
	# Every body value passed the gates above (allowlisted voucher; strict or
	# empty MAC; strict IPv4 or neutral-empty; token-safe charset or
	# neutral-empty; operator PSK), so no value can alter the form structure
	# (&, =, %, CR, LF cannot occur). Resume posts to the /resume sibling
	# (URL must end /claim; otherwise fail closed) with NO voucher field.
	vresp=""
	vurl="$VOUCHER_API_URL"
	if [ -z "$vdeny" ] && [ "$vresume" = "1" ]; then
		case "$vurl" in
			*/claim)
				vurl="${vurl%/claim}/resume"
				;;
			*)
				vdeny="no_api_url"
				;;
		esac
	fi
	if [ -z "$vdeny" ]; then
		if [ "$vresume" = "1" ]; then
			vpost="mac=$vmac&ip=$vip&token=$vtoken&psk=$vpsk"
		else
			vpost="voucher=$vnorm&mac=$vmac&ip=$vip&token=$vtoken&psk=$vpsk"
		fi
		vpsk=""
		if command -v uclient-fetch >/dev/null 2>&1; then
			vresp=$(uclient-fetch -q -T "$VOUCHER_TIMEOUT" -O - --post-data="$vpost" "$vurl" 2>/dev/null)
		elif command -v wget >/dev/null 2>&1; then
			vresp=$(wget -q -T "$VOUCHER_TIMEOUT" -O - --post-data="$vpost" "$vurl" 2>/dev/null)
		else
			vdeny="no_http_client"
		fi
		vpost=""
	fi
	vurl=""

	# --- parse line response (strict shape, validated numerics) ---
	# Accept ONLY:
	#   ALLOW <remaining_seconds> <up_kbps> <down_kbps>
	#   ALLOW <remaining_seconds> <up_kbps> <down_kbps> EVICT <oldmac>
	# Anything else (bare ALLOW, non-numeric/negative/oversized values,
	# wrong field count, bad EVICT) => DENY. First line only.
	vremaining=""
	vup=""
	vdown=""
	vevict=""
	if [ -z "$vdeny" ]; then
		vline=$(printf '%s' "$vresp" | head -n 1)
		vdecision=$(printf '%s' "$vline" | awk '{print $1}')
		vnf=$(printf '%s' "$vline" | awk '{print NF}')
		vline=""
		if [ "$vdecision" = "ALLOW" ]; then
			case "$vnf" in
				4|6)
					;;
				*)
					vdeny="bad_reply"
					;;
			esac
			if [ -z "$vdeny" ]; then
				vremaining=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
				vup=$(printf '%s' "$vresp" | awk 'NR==1{print $3}')
				vdown=$(printf '%s' "$vresp" | awk 'NR==1{print $4}')
				case "$vremaining" in ""|*[!0-9]*) vdeny="bad_reply";; esac
				case "$vup" in ""|*[!0-9]*) vdeny="bad_reply";; esac
				case "$vdown" in ""|*[!0-9]*) vdeny="bad_reply";; esac
				# Bounds: remaining <= 9999999 (~115 days, far above any plan);
				# rates <= 1000000 kb/s. openNDS session cap applied below.
				if [ -z "$vdeny" ]; then
					if [ "${#vremaining}" -gt 7 ] || [ "${#vup}" -gt 7 ] || [ "${#vdown}" -gt 7 ]; then
						vdeny="bad_reply"
					elif [ "$vup" -gt 1000000 ] 2>/dev/null || [ "$vdown" -gt 1000000 ] 2>/dev/null; then
						vdeny="bad_reply"
					fi
				fi
				if [ -z "$vdeny" ] && [ "$vremaining" -le 0 ] 2>/dev/null; then
					vdeny="no_remaining"
				fi
			fi
			if [ -z "$vdeny" ] && [ "$vnf" -eq 6 ]; then
				vfifth=$(printf '%s' "$vresp" | awk 'NR==1{print $5}')
				vsixth=$(printf '%s' "$vresp" | awk 'NR==1{print $6}')
				if [ "$vfifth" != "EVICT" ]; then
					vdeny="bad_reply"
				else
					case "$vsixth" in
						??:??:??:??:??:??)
							case "$vsixth" in
								*[!0-9a-fA-F:]*)
									vdeny="bad_reply"
									;;
								*)
									vevict="$vsixth"
									;;
							esac
							;;
						*)
							vdeny="bad_reply"
							;;
					esac
				fi
				vfifth=""
				vsixth=""
			fi
		elif [ "$vdecision" = "DENY" ]; then
			vdeny="backend_deny"
		else
			vdeny="bad_reply"
		fi
		vdecision=""
		vnf=""
	fi
	vresp=""

	# Secondary methods confirm-or-deny only: a stranger's binding restores
	# parent defaults (abstain) instead of moving it.
	if [ -z "$vdeny" ] && [ "$vneutral" = "1" ] && [ -n "$vevict" ]; then
		session_length=0
		upload_rate=0
		download_rate=0
		upload_quota=0
		download_quota=0
		exitlevel=0
		if command -v logger >/dev/null 2>&1; then
			logger -t opennds-voucher "decision=abstain reason=bound-elsewhere mac=$vmac method=$vmethod" 2>/dev/null
		fi
		vnorm=""
		vremaining=""
		vup=""
		vdown=""
		vevict=""
		vdeny=""
		return
	fi

	# --- apply decision to parent contract (fail-closed) ---
	if [ -n "$vdeny" ]; then
		exitlevel=1
		session_length=0
		upload_rate=0
		download_rate=0
		upload_quota=0
		download_quota=0
	else
		# ceil(remaining_secs/60): openNDS session granularity is minutes.
		session_length=$(( (vremaining + 59) / 60 ))
		if [ "$session_length" -gt 1440 ]; then
			session_length=1440
		fi
		upload_rate="$vup"
		download_rate="$vdown"
		upload_quota=0
		download_quota=0
		exitlevel=0

		# Best-effort single-session eviction of the superseded device.
		# Async daemon hook (documented for binauth callers); never fatal:
		# a failed evict leaves the old record to expire naturally.
		if [ -n "$vevict" ] && [ "$vevict" != "$vmac" ]; then
			if [ -x "$VOUCHER_LIBOPENDS" ]; then
				("$VOUCHER_LIBOPENDS" daemon_deauth "$vevict" >/dev/null 2>&1 &)
			fi
		fi
	fi

	# --- masked syslog (no voucher value, no PSK, no custom) ---
	if command -v logger >/dev/null 2>&1; then
		if [ -n "$vdeny" ]; then
			logger -t opennds-voucher "decision=deny reason=$vdeny mac=$vmac method=$vmethod" 2>/dev/null
		elif [ "$vresume" = "1" ]; then
			# Resume path carries no voucher value at all: log the MAC-bound
			# grant only.
			logger -t opennds-voucher "decision=allow resume=1 mac=$vmac sess_min=$session_length method=$vmethod" 2>/dev/null
		else
			# POSIX-only suffix (no `rev`: absent on busybox/OpenWrt).
			vpre=$(printf '%s' "$vnorm" | cut -c1-2)
			vlen2=${#vnorm}
			vpost_mask=$(printf '%s' "$vnorm" | cut -c"$((vlen2 - 1))"-)
			logger -t opennds-voucher "decision=allow voucher=${vpre}***${vpost_mask} mac=$vmac sess_min=$session_length method=$vmethod" 2>/dev/null
			vpre=""
			vpost_mask=""
			vlen2=""
		fi
	fi

	vnorm=""
	vremaining=""
	vup=""
	vdown=""
	vevict=""
	vdeny=""
	vresume=""
}

if [ "$action" = "auth_client" ]; then
	vdeny=""

	# --- 1. decode custom (only ndsctl verb allowed here) ---
	vdecoded=""
	if [ -z "$vdeny" ]; then
		vdecoded=$(ndsctl b64decode "$custom" 2>/dev/null)
		if [ -z "$vdecoded" ]; then
			vdeny="bad_custom"
		fi
	fi

	# --- 1b. codeless resume marker (exact match ONLY) ---
	# The ThemeSpec resume flow encodes exactly "resume" after its own backend
	# pre-check; anything else (resume=1, resumeX, voucher pairs) is NOT a
	# resume and falls into the voucher path below (which denies it). The MAC
	# below is server-side ($2); the backend enforces the binding.
	vresume=0
	if [ -z "$vdeny" ] && [ "$vdecoded" = "resume" ]; then
		vresume=1
	fi

	# --- 2. extract voucher field (format "voucher=<code>", comma-separated) ---
	vraw=""
	if [ -z "$vdeny" ] && [ "$vresume" != "1" ]; then
		vraw=$(printf '%s' "$vdecoded" | tr ',' '\n' | grep '^voucher=' | head -n 1)
		vraw=${vraw#voucher=}
		vraw=$(printf '%s' "$vraw" | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
		if [ -z "$vraw" ]; then
			vdeny="missing_voucher"
		fi
	fi

	# --- 3. normalize + strict allowlist (hyphens significant, uppercase) ---
	# Entity-encoded smuggling (e.g. &#59;) can never match: & # ; are outside
	# the set, so such input falls into DENY below. No entity-decoding here.
	vnorm=""
	if [ -z "$vdeny" ] && [ "$vresume" != "1" ]; then
		vnorm=$(printf '%s' "$vraw" | tr 'a-z' 'A-Z')
		vlen=${#vnorm}
		if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
			vdeny="bad_length"
		else
			case "$vnorm" in
				*[!A-Z0-9-]*)
					vdeny="bad_charset"
					;;
			esac
		fi
	fi

	# --- 4. client metadata from BinAuth positionals (transient, not identity) ---
	# auth_client: $2 mac, $5 ip, $6 token (binauth_log.sh:160-168).
	# Nothing here is trusted: every field is allowlisted before it may enter
	# the claim POST body, so no value can inject extra form fields
	# (&, =, %, CR, LF and friends are all outside the allowed sets).
	vmac="$2"
	vip="$5"
	vtoken="$6"

	# MAC: strict XX:XX:XX:XX:XX:XX (six hex octets) else empty-and-continue.
	# An absent/unparseable MAC never fails the claim; it is metadata only.
	case "$vmac" in
		??:??:??:??:??:??)
			case "$vmac" in
				*[!0-9a-fA-F:]*)
					vmac=""
					;;
			esac
			;;
		*)
			vmac=""
			;;
	esac

	# IP: strict IPv4 dotted quad (covers 10.0.0.0/24 LAN). Malformed => deny
	# here, before any network call, so it can never reach the POST body.
	if [ -z "$vdeny" ]; then
		vip_ok=1
		case "$vip" in
			*.*.*.*)
				case "$vip" in
					*[!0-9.]*)
						vip_ok=0
						;;
					*)
						vo_rest="$vip"
						vo_parts=0
						while [ -n "$vo_rest" ] && [ "$vip_ok" -eq 1 ]; do
							vo_parts=$((vo_parts + 1))
							case "$vo_rest" in
								*.*)
									vo_oct=${vo_rest%%.*}
									vo_rest=${vo_rest#*.}
									;;
								*)
									vo_oct=$vo_rest
									vo_rest=""
									;;
							esac
							case "$vo_oct" in
								""|*[!0-9]*|????*)
									vip_ok=0
									;;
								*)
									if [ "$vo_oct" -gt 255 ] 2>/dev/null; then
										vip_ok=0
									fi
									;;
							esac
						done
						if [ "$vo_parts" -ne 4 ]; then
							vip_ok=0
						fi
						vo_rest=""
						vo_parts=0
						vo_oct=""
						;;
				esac
				;;
			*)
				vip_ok=0
				;;
		esac
		if [ "$vip_ok" -ne 1 ]; then
			vdeny="bad_ip"
		fi
		vip_ok=""
	fi

	# Token: restricted to the OpenNDS-token-safe set, 1..128 chars.
	# Empty or anything outside [A-Za-z0-9._:-] (notably & = % CR LF) => deny.
	if [ -z "$vdeny" ]; then
		vtoklen=${#vtoken}
		if [ "$vtoklen" -lt 1 ] || [ "$vtoklen" -gt 128 ]; then
			vdeny="bad_token"
		else
			case "$vtoken" in
				*[!A-Za-z0-9._:-]*)
					vdeny="bad_token"
					;;
			esac
		fi
		vtoklen=""
	fi

	# --- backend claim (shared): validates via backend, applies contract. ---
	# Unconditional: vbackend_claim honors a pre-set vdeny (gate failures
	# above) by skipping fetch/parse and enforcing the deny in apply.
	vneutral=0
	vmethod="$action"
	vbackend_claim

	# Branch-local extraction vars (backend vars were cleaned by the call).
	vraw=""
	vdecoded=""
	vlen=""

	# (backend stages removed here: the shared vbackend_claim call above
	# performs config/fetch/parse/apply/log identically.)
else
	case "$action" in
		*deauth)
			# Pause-recording: report the ended interval to the backend, which
			# accrues it idempotently (button path and this callback both fire
			# safely; repeats are silent no-ops). Parent contract untouched:
			# callbacks cannot grant, exitlevel/quotas are never assigned here.
			# Reason vocabulary is fixed server-side; derive the suffix from
			# $1 directly ($action is rewritten, so $1 is the only source).
			# Only bare suffix words ever leave this box (never raw $1).
			case "$1" in
				*_deauth)
					vwhy=${1%_deauth}
					;;
				*)
					vwhy="deauth"
					;;
			esac
			case "$vwhy" in
				idle|timeout|client|shutdown|ndsctl|deauth)
					;;
				*)
					vwhy="deauth"
					;;
			esac
			# MAC + voucher: strict-or-empty metadata only (server revalidates;
			# empty values simply match nothing -> idempotent no-op).
			vmac="$2"
			case "$vmac" in
				??:??:??:??:??:??)
					case "$vmac" in
						*[!0-9a-fA-F:]*)
							vmac=""
							;;
					esac
					;;
				*)
					vmac=""
					;;
			esac
			vcode=""
			vdecoded=$(ndsctl b64decode "$custom" 2>/dev/null)
			if [ -n "$vdecoded" ]; then
				vraw=$(printf '%s' "$vdecoded" | tr ',' '\n' | grep '^voucher=' | head -n 1)
				vraw=${vraw#voucher=}
				vraw=$(printf '%s' "$vraw" | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
				vnorm=$(printf '%s' "$vraw" | tr 'a-z' 'A-Z')
				vlen=${#vnorm}
				if [ "$vlen" -ge 4 ] && [ "$vlen" -le 20 ]; then
					case "$vnorm" in
						*[!A-Z0-9-]*)
							;;
						*)
							vcode="$vnorm"
							;;
					esac
				fi
				vlen=""
				vnorm=""
				vraw=""
				vdecoded=""
			fi
			# Config + endpoint: pause lives next to claim (URL must end
			# /claim; otherwise skip quietly — recording is best-effort).
			# PSK handling mirrors the claim path (0600 file, never logged).
			if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
				VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
			fi
			vpskfile="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
			case "$VOUCHER_API_URL" in
				*/claim)
					if [ -f "$vpskfile" ]; then
						vpsk=$(cat "$vpskfile" 2>/dev/null)
						if [ -n "$vpsk" ]; then
							vpause_url="${VOUCHER_API_URL%/claim}/pause"
							vpost="mac=$vmac&code=$vcode&why=$vwhy&psk=$vpsk"
							vpsk=""
							if command -v uclient-fetch >/dev/null 2>&1; then
								uclient-fetch -q -T "$VOUCHER_TIMEOUT" -O - --post-data="$vpost" "$vpause_url" >/dev/null 2>&1
							elif command -v wget >/dev/null 2>&1; then
								wget -q -T "$VOUCHER_TIMEOUT" -O - --post-data="$vpost" "$vpause_url" >/dev/null 2>&1
							fi
							vpost=""
							vpause_url=""
						fi
					fi
					;;
			esac
			vpskfile=""
			vmac=""
			vcode=""
			vwhy=""
			;;
		*)
			# Secondary grant-capable path (the ndsctl_auth family and any
			# unknown non-deauth method): validate ONLY when a voucher=
			# claim is present; otherwise abstain with defaults untouched.
			# Positional slots are unreliable here ($5/$6 are NOT ip/token),
			# so metadata stays neutral (strict-or-empty MAC, empty ip/token):
			# empty values cannot inject, and the voucher alone decides.
			vdeny=""
			vdecoded=""
			vdecoded=$(ndsctl b64decode "$custom" 2>/dev/null)
			vraw=""
			vnorm=""
			vresume=0
			if [ "$vdecoded" = "resume" ]; then
				# Codeless resume marker (exact match only): MAC below is
				# server-side ($2); the backend enforces the binding.
				vresume=1
			elif [ -n "$vdecoded" ]; then
				vraw=$(printf '%s' "$vdecoded" | tr ',' '\n' | grep '^voucher=' | head -n 1)
				vraw=${vraw#voucher=}
				vraw=$(printf '%s' "$vraw" | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
				if [ -n "$vraw" ]; then
					vnorm=$(printf '%s' "$vraw" | tr 'a-z' 'A-Z')
					vlen=${#vnorm}
					if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
						vdeny="bad_length"
					else
						case "$vnorm" in
							*[!A-Z0-9-]*)
								vdeny="bad_charset"
								;;
						esac
					fi
					vlen=""
				fi
			fi
			if [ -z "$vnorm" ] && [ -z "$vdeny" ] && [ "$vresume" != "1" ]; then
				# No voucher claim carried: abstain, parent defaults intact.
				vdecoded=""
				vraw=""
				vresume=""
			elif [ -n "$vdeny" ]; then
				# Malformed voucher= carried: fail closed (generic page).
				exitlevel=1
				session_length=0
				upload_rate=0
				download_rate=0
				upload_quota=0
				download_quota=0
				if command -v logger >/dev/null 2>&1; then
					logger -t opennds-voucher "decision=deny reason=$vdeny mac=$2 method=$action" 2>/dev/null
				fi
				vdecoded=""
				vraw=""
				vnorm=""
				vdeny=""
				vresume=""
			else
				vmac="$2"
				case "$vmac" in
					??:??:??:??:??:??)
						case "$vmac" in
							*[!0-9a-fA-F:]*)
								vmac=""
								;;
						esac
						;;
					*)
						vmac=""
						;;
				esac
				vip=""
				vtoken=""
				vneutral=1
				vmethod="$action"
				vbackend_claim
				vmac=""
				vip=""
				vtoken=""
				vdecoded=""
				vraw=""
			fi
			;;
	esac
fi

# Fall off the end WITHOUT exit/return so binauth_log.sh continues to
# echo the quotas and exit with $exitlevel (binauth_log.sh:300-309).
