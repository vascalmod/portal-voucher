#!/bin/sh
# voucher_admin.sh — simple operator helper for the portal_voucher database.
# Usage:
#   sh voucher_admin.sh list
#   sh voucher_admin.sh create <CODE> [total_secs]
#   sh voucher_admin.sh delete <CODE>
# Examples:
#   sh voucher_admin.sh list
#   sh voucher_admin.sh create TEST-12H 43200
#   sh voucher_admin.sh create GUEST-001        # default 21600 (6h)
#   sh voucher_admin.sh delete GUEST-001
#
# Reads DATABASE_URL from .env.production next to this script (never prints
# secrets). Requires psql. Codes are normalized to UPPER and must match
# A-Z0-9- (4..20 chars), same allowlist as backend/api.py.
set -u

HERE=$(dirname "$0")
ENV_FILE="$HERE/.env.production"

if [ ! -f "$ENV_FILE" ]; then
	echo "missing $ENV_FILE" >&2
	exit 1
fi
if ! command -v psql >/dev/null 2>&1; then
	echo "psql not found" >&2
	exit 1
fi

# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

if [ -z "${DATABASE_URL:-}" ]; then
	echo "DATABASE_URL is empty" >&2
	exit 1
fi

cmd="${1:-list}"

if [ "$cmd" = "list" ]; then
	psql "$DATABASE_URL" -c "SELECT code, total_secs, used_secs, (total_secs-used_secs) AS remaining, state, bound_mac, last_ip, last_auth FROM vouchers ORDER BY code;"
	exit $?
fi

if [ "$cmd" = "create" ]; then
	code=$(printf '%s' "${2:-}" | tr 'a-z' 'A-Z')
	secs="${3:-21600}"
	case "$code" in
		*[!A-Z0-9-]*|"")
			echo "bad code (A-Z0-9-, 4..20 chars): ${2:-}" >&2
			exit 1
			;;
	esac
	len=${#code}
	if [ "$len" -lt 4 ] || [ "$len" -gt 20 ]; then
		echo "bad code length (4..20): $code" >&2
		exit 1
	fi
	case "$secs" in
		""|*[!0-9]*)
			echo "bad total_secs: $secs" >&2
			exit 1
			;;
	esac
	psql "$DATABASE_URL" -c "INSERT INTO vouchers (code, total_secs, used_secs, state) VALUES ('$code', $secs, 0, 'NEW') ON CONFLICT (code) DO NOTHING RETURNING code, total_secs, state;"
	exit $?
fi

if [ "$cmd" = "delete" ]; then
	code=$(printf '%s' "${2:-}" | tr 'a-z' 'A-Z')
	case "$code" in
		*[!A-Z0-9-]*|"")
			echo "bad code: ${2:-}" >&2
			exit 1
			;;
	esac
	psql "$DATABASE_URL" -c "DELETE FROM events WHERE code='$code';" -c "DELETE FROM vouchers WHERE code='$code' RETURNING code, state;"
	exit $?
fi

echo "usage: sh voucher_admin.sh list | create <CODE> [total_secs] | delete <CODE>" >&2
exit 1
