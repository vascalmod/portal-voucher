#!/bin/sh
# tests/stage1_guard.sh — regression guard: Stage 1 frozen files untouched,
# Stage 2 files confined to their scope. Run: sh tests/stage1_guard.sh
cd "$(dirname "$0")/.." || exit 1
FAIL=0

echo "--- frozen-file manifest ---"
if sha256sum -c tests/stage1_manifest.sha256; then
	echo "manifest: OK (theme_voucher.sh + 3 openNDS core files unchanged)"
else
	echo "manifest: MODIFIED STAGE 1 FILE DETECTED"
	FAIL=1
fi

echo "--- scope guards (must print nothing) ---"
# Full-line '#' comments are stripped first: the guard polices CODE, while
# prose (e.g. theme scope notes) may name these areas to forbid them.
# This guard script itself is excluded: it necessarily spells patterns out.
# (PAUSED-state *deny handling* is required Stage 2 behavior and is
# intentionally NOT matched; only accrual hooks are.)
scope_fail=0
# NOTE: test files are excluded by design — they must spell BinAuth method
# names (e.g. timeout_deauth) to exercise them. Only shipped code is policed.
for f in custombinauth.voucher.sh theme_voucher.sh client_params_voucher.sh backend/api.py; do
	# NOTE: only grant-capable verbs are forbidden. Read-only `ndsctl json` /
	# `ndsctl status` queries are allowed: the theme status timer reads
	# session_end exactly like stock client_params.sh does.
	if sed 's/^[[:space:]]*#.*$//' "$f" | grep -n -E "uci set|statuspath|gatewayport|gatewayinterface|iptables|nft (add|delete|insert|replace|flush)|ndsctl (auth|deauth)|idle_deauth|timeout_deauth|while true"; then
		echo "guard: FORBIDDEN STRING PRESENT in $f"
		scope_fail=1
	fi
done
if [ "$scope_fail" -ne 0 ]; then
	FAIL=1
else
	echo "scope: OK"
fi

echo "--- usage-accrual guard (must print nothing) ---"
# No Stage-2 file may increment used_secs (Stage 3 accounting only).
if grep -rn -E "used_secs['\" ]*=[^=]*used_secs\s*\+|used_secs\s*\+=" custombinauth.voucher.sh backend/api.py backend/test_api.py backend/test_pg.py backend/test_server.py tests/custombinauth_test.sh 2>/dev/null | grep -v "stage1_guard"; then
	echo "guard: USAGE ACCRUAL PRESENT"
	FAIL=1
else
	echo "accrual: OK (none)"
fi

echo "--- forbidden-string allowlist check ---"
# daemon_deauth (async hook) is the only sanctioned openNDS call besides b64*;
# confirm no bare 'ndsctl auth|deauth' hides behind it.
if grep -rn "ndsctl" custombinauth.voucher.sh | grep -v "b64\|daemon hook\|documented\|ndsctl verb\|ndsctl_auth\|ndsctl-driven"; then
	echo "guard: unexpected ndsctl usage"
	FAIL=1
else
	echo "ndsctl-surface: OK (b64decode + daemon hook only)"
fi

[ "$FAIL" -eq 0 ] && echo "GUARD PASS" || echo "GUARD FAIL"
exit $FAIL
