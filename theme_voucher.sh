#!/bin/sh
# theme_voucher.sh — Stage 2 local OpenNDS ThemeSpec (voucher login + status UI)
#
# STAGE 2 — REAL VALIDATION (voucher backend authoritative).
# - Flow (no intermediate Continue tap; CPD-friendly):
#   login form (CONNECT) -> FAS -> $voucher -> backend pre-validation
#   -> on ALLOW only: encode_custom -> auth_log (explicit quotas in request)
#   -> custom status page (CONNECTED + remaining). On DENY/failure the auth
#   call is SKIPPED entirely: no call, no grant possible (fail closed by
#   construction — enforced here because this daemon honors request quotas
#   and may skip BinAuth on the FAS path).
# - Legacy thankyou -> landing two-step kept as fallback, hardened identically
#   (presence gate + pre-validation + re-encoded custom).
# - "PORTAL-TEST" is retired: it is NOT seeded in the backend and MUST deny.
#   Use a labeled TEST-* code from backend/seed.sql for local/manual tests.
#   No code is hard-coded as valid here; any non-empty voucher reaches BinAuth
#   and the backend decides (exitlevel=1 denies).
# - Rates/session/quotas are set by custombinauth.voucher.sh from the backend
#   response, not here (quotas below stay 0 = defaults until BinAuth overrides).
# - PAUSE/RESUME actions, unified status.client entrypoint and port-80 changes
#   remain Stage 3. The legacy thankyou/landing two-step is kept only as a
#   compatible fallback and is no longer the primary flow.
#
# Privacy:
# - The raw voucher / custom values are NEVER rendered except where the approved
#   UI requires them:
#   (a) login input value="$voucher" (preserved re-serve, entity-encoded by core),
#   (b) hidden fas / voucher / custom fields of the legacy thankyou -> landing
#       fallback (FAS protocol requirement),
#   (c) the status page shows the user their OWN active voucher code, exactly as
#       the approved status.html mockup does (entity-encoded by core).
# - userinfo intentionally does NOT contain the voucher value (marker only).
#
# Failure UX: failures re-render the LOGIN page itself with an inline error
# banner (code preserved for correction) — no separate error page. Text comes
# from a fixed vocabulary (expired / in-use / required / invalid / retry).
# Unknown, disabled and malformed codes deliberately share ONE message
# (anti-enumeration); transport failures share the retry message. Denied
# attempts write a masked server-side log line (reason + client MAC only).
#
# Loading UX: submit buttons carry a CSS spinner + disabled state driven by a
# tiny inline script (progressive enhancement ONLY — inert where JS is
# blocked, e.g. strict CPD). Correctness never depends on it: the backend
# claim is idempotent, so a duplicate submit cannot double-spend time.
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
	# Direct path: a submitted voucher authenticates immediately and renders
	# the custom status page — no intermediate Continue tap (CPD-friendly).
	# Presence gate only, NOT authorization: the backend decides via BinAuth.
	if [ ! -z "$voucher" ]; then
		voucher_status_page
		footer
	fi

	# Codeless resume path: the PAUSED portal's Resume button lands here with
	# resume=1 (no voucher value anywhere). The backend decides by the
	# server-side client MAC; BinAuth re-verifies before granting.
	# NOTE: MHD does NOT reliably forward ?resume=1 as a FAS variable — it
	# often survives only inside $originurl/$cpi_query, and in established
	# browser/CPD sessions even that is pinned to the session's first URL.
	# So this detection is best-effort only; the guaranteed path is the
	# confirm page's in-flow resume form below. Safe either way: the flag
	# alone grants nothing — the backend MAC check and the BinAuth
	# re-verification still decide, and a client can only ever resume a
	# voucher bound to its own server-side MAC.
	if [ -z "$resume" ]; then
		# (dash rejects a literal & inside case patterns, so the
		# entity-encoded alternative lives in a variable: same match.)
		vresume_enc='*resume&#37;3D1*'
		case "$originurl $cpi_query" in
			*resume=1*|$vresume_enc)
				resume=1
				;;
		esac
		vresume_enc=""
	fi
	if [ ! -z "$resume" ]; then
		voucher_resume_page
		footer
	fi

	# ACTIVE auto-relogin: a reconnected client whose bound voucher is still
	# ACTIVE is granted immediately with zero clicks and no code — the same
	# backend-verified resume chain as above (on ACTIVE it returns rerequest,
	# keeping resume_ts: no new interval, no extra time).
	# CPD/paused entry: a PAUSED voucher is NOT granted here (explicit Resume
	# tap still required). The theme renders a CONFIRM page whose Resume
	# button posts fas+resume=1 inside the FAS flow itself — a genuine FAS
	# variable, the only intent channel that survives every browser and CPD
	# webview (MHD pins cpi_query/originurl to the session's first URL, so
	# query-string intent is unreliable). EXPIRED renders the terminal
	# expired page. Anything else (or any lookup failure) falls through to
	# the plain login form: fail closed to code entry, never to a grant.
	if [ -z "$voucher" ]; then
		voucher_api_state_check
		case "$vstate" in
			active)
				voucher_resume_page
				footer
				;;
			paused)
				voucher_paused_confirm_page
				footer
				;;
			expired)
				voucher_expired_page
				footer
				;;
		esac
		vstate=""
		vremain=""
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
		<link rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAPr0lEQVR42sVae3Ad1Xn/vrNn70tXT9uSbGPAVqhtFASyHYPTYMIEMjF0mqZAm2HMo2CmDIEw6UxbSNOmmQlDH2lpwyNpCG4MBGiGSZuEUisUDMTYDhhkgx/IBlk2siVZ1vPq6j529/z6x77O7r2SXyHdkX337j179pzv+ft+33Lrhs10SgcTQf8OIo6chAOCn/wbKXYvEYHYHwaO33KSA0QEZgaIJaLP5lO4ORit/8/aEkGsfY1vOxzuDfLmO+keggFMROzNJOF+9SdVTOyLJBxFJPxnuONRKRJ/I9quOLaxYHvuj5pqwrtYlwlBH0PQV+Rdkr4i2ROcr9yYNpT2raqhgJjhPzBYJcUtiSrmce9yHwxPMayJINgDmLlSJxIAE4Ndk0TlA6p5A4gYrH8l9wp7imJXY4pY2wk0i4/4iCDAO6Fq2wa7oo1ZI5gIwt0Wo6q2XXNCcMKhDiM+w96AwGwCDSHqGzG9hE9lIgIDrC/dmwdVLFYpb5AM3ZLdD4SSjFgna7bPUQ+NeIV7M9jVJtwbw2HwlcBEnlw102dtNUQMEAejIgYdPE3CNV4/FHBkKRUq8ab0dhDKPCbbYP9gjhl+sHZfAir0W0CbDIGjB16ge7QrTwVBBIInGdKjQxUfAIhYwXNW9swDfhxx/9z5uJq1eCvxLAXBin2F+qJGLAbDM/hABCJYDgkW7KqA4D59tuzB8Gf0VeAZivcVBGhB0PWbMGWxN6IyEMP7C8fCN6lAFIzYCpmYSfrGyJV5jPWIHGQdjgiJdZ2zllB8s4ZnDmH0D6MdSLC/UAL8BBuxyMCY4IZb9rzUNxYRTA2ulp+gfXJoGdFMwd4vTBzaknYTAuNgP9D4VujaL8eyNMfzCOBfdtUKLxoAEgg0ROAquTv0VC12MgIXB4NjD/TV6atHMBDqDe4voVnpugndNRKu2RN6KDh4KpNhjAI43CURE0Q0lEbiDMhPZuw/WDAxM4hsBcuBcpRSBEAIloaQgg2DBLMCKYQbhp+IvE+Opw1U5nBiEsQgADLMccxBWAjMn8FwAy0jEig02TArwUIpyhftou1IwfUZs6UhUZ+RmaQgwnQJ49P26FR5smDbDhJSZpLSEGRDBcIGxyKx5su6IzKCeMNMTCwJ1QCLt1Z2s1oQuNnzplAsUpDl8Nh0OW3yiiV1a5c3XXpB49IFtfPqk5mkNIQggqOQL9nDE6WDA1M7Do5u3T/W3TeZL6n6jGkabKsw6jKFLq+lGqYYpNMAATdv6IogvADZkOEmPcSRtud3QjAxxvPluVl5/ZoFf/y7C1a1NRlCnBzNAzs/HH1ua/9Pfz00OF5uqE0wsaMFeh106h4YOF1E5C0bulAdsbGHownQczeBQFKIqZLD5Ny0duG917a1tdbq9+aL1uB4YXiyPFV0iCibNubWJlob0tmUqQ/rHco99MIHz2wdcMA1KWk7SgMR5OJLPx/r22Mm+HGIuOW2zYGPVyKuQA/sRTIQkRR8ImddeE76Oze3X/nJlmDwoaGprl1Dr+078f7R/PCkNW0pR4GZDMFpk+fVJpcuzFy+vGldZ+uSlnDDv9o//Geb9uz5aHpurWk7QJAtQ3xEECBEsKqXzAFuuW0zEUHwDMjZIAKT8k0OhiFGcuXrLp376IZLGmqSCiSYug+NPvLioa7dw2PTjhCCmRUAD6GAiFmwYAYA5TTVmJ+7qOkr65asapvjYr2J6fLdT+x+fvvxpmzCdhQzaxidggorogf/lFtu7yICeKYNiADPMkgwj+SKd687759u6VAKQvBkofytn+z/0ZajZZtSSaNgKYPRWpdY3Jxe2JRqrDFBNJG3jo4Ve48XhibKUJQwjYLlJCXdvHbhN/9oWUNN0p3qL55891//u6+pLgXoVacGrgLP1VF3y+1dgbvwbFiIDKZcwbnlitZHNnSWLJU0xTu9o3c81r3vaLExm8gVyk1ZeU1n8xc/1bqiraG5PhULi8cnit2Hxn/25uCL3cdPTDl1aXNsqrx0fvKHd3WuapvjTnjvxl3/vmUgmzaU8sOdj/GJg8AUyZrcfNtmDwhF65kYl8BELDg/Xdrx4OUXnlNPRF27jt36yLslm6RBjnJuveKcr6xbohv3TEff8anHuno3vtIvhHAA0+CNd3Zcs3IBEfUcm1h936+yqYQCwvogjsw0HoPJyK5YHxSEQT4TFQSBm5fLNhVtq+Pcuq5dg3/ySLcwTAe0oEH+6O7OP/18W2M26Q4ez5d2fjj2yt7hl987vu3ASM+xyVzBqk0b6YQkooaaxNUXt3x6Wf3W90+MTytDiJ+80X/uvGRDxvznX3ywuy+fTAjPaoMgGoBeZr/CCXxgw2b2YUQM4nIM94KYqGA59WnOFVQqYeaK5U8tyT73tdUtDWlHwRC869Do4/97eMuekYHxclmFRmBKaq1PXNnetOFz561sm+Ma/fBk8caH3tpxcCJbkywU7doUTxaQTho6K+EWd743IzQNeNUet9y+OQKCg+AfIKII/CEhyHEgDS6WsXRB6uf3r55bmyai6ZL1jWf3btpytGRzKmFYjrIVAiBpSGEKUbLspEHr187/9o3ttekEQOP50hf//td7+/Mp07BskpIdBR0l6Vbk44igOgUzS+0as+7KOiZHWFcouEQAT0wXr1+z2F39kRP5m7779vaeibl1qbJjJSU+s7S+c3H9ojlpYuofKb5zaOKtDyZLZUomzO+/1L+zd/Lpe1csbq5tzCavv2z+9k3vpxulYKVUpJDVo01gTSFpxUwMqWd4Fx4h4jQcGpNW6Csgmzaf3zGwbkVL2Va3PvzOgYHivIZ0vli+5bPz7/rCEtfR9WN//8RjXb1Pv35sbn3q3cP5339wx6Z7VmZT8vntA9m0VMqth6rFQg7KY41w81yW3UysEQMcVl/QitQoLAFAgrlQVhmTHCjLEaYgw8AP7rz491YumCUEbe4euON7u4sOgdhgZTAXLEonhPIKLhcIxeB7jGuNFC5hHog6r586vLIhllm8i4I9ECaYQerpr158Vcd8y4Ypec+RsRd2Dn4wmAfoE601165q7Tiv0XJgGvz63qEv/8suMEMRQIYghUgNWcEghkt3Yb22JpKB/VAA78PqyC2egAg3FBaqChBEQlCu4Hx6ae1VHfOJSBr4qx/v+d4vjxQsMgQTSAH/+PPeO65a9MCN7UTG2vaWzvOzr+2bqK8xFeCCDo1TrCzMQxpZC0+udMmo6VyvVQCR8tGt+0CVPAtHaEqQafLIlHXB/HQmYfz5U3se/p8jDTVJaQgCWFDKNJKmfGn3iUPHp1a1Nbzx/oknXu4XQgRUGTN7BXWELgsKxKDkd0fqciZuvm1zZAMcMXrNBxCEAA84IRSIYLIcYihT0sCY1dqYKlmqfVHm61+6QAh68KcHd/XlM0ljYKw4vylhWVDECcnwkDFpfC7HqWOOuWAsGZOMMXC6/TFi3HOMKQhPFChhsKO4Nm1e3TGvuy93bLTw+J0XL1tYT0Rtrdk1929tzJpXdzTtODg+5thJIVy7R0jVQA+aWg8CVfoGCFjKGB8M8EydlBBAscc2+Vmd/SNXdC5fXr/pnlXzG2Q6YSxpyVoOLAeLm2uyKaO13tx0z6or25vyRVsIinktwAHRoAkYAeWlMT2+1tgLJN4SYjtEjBUPuECX/w1LfNZTZbEMpSANMTRuPfnaYdNg0+CnXjt8bKSYNIVSmCraJRuCI9qNM6k6Px2sj0EMjWFGJArpHsyhIUV7RRxLzhELVaCUKboPTTDTDWsWvvjOib9+9sBLu4eZ6PX942UHf7C6hQX1jxQ+uaimd6hUl5GWW0NCq+epWmHok2Ec4Vl9kF+z8ibWsRuDozWll9l8Vjl0OR9sBbgwIcWxsdLiltTNV5x/4Nj42725AwOFPR9N5Uv2DZe1/t36i/7tlx+O562n7l3V1T3w0UipJiUdFRoHswjSTJhRQ2KTQw5Qs3Oj5pL1kSqeg0znaZD87k1ACHsMIioIGSZTGq++N/yZZQ1fvfZ3li3IHBnOX3Je9ps3XPCtL7dv6zlx/9N7Hr2j8/zm7Bc65215b3hgrJxKCBXS5QEBHIvUsZOQ0GSO5QGKMqBVGlz+vKC47REBJAUXLfznm4NE9oarlvQczV136YI/vGzRQ7848LfP7f3+nStWfWJO2VZN2eS1K5qf33ZkbBrphFDw8qXXLmKK+yQQUpXRMCOqBsZI0otHJBdJRD3Db2IpUCohiha+/kzPSK5oK6doO2Xb2fhK36vf/uwV7c22QkKKQtk+Mpz7r/suW74wPZa3pCF0hjzSC3IDStAkq+gARDYQihJ+AEOVABwvNhGAI9ebYRjUmE1KQzCTKfnt3rHpaTWaK7vPmypab+wfPHde7YWLGp792orlCzOFsiOEKwoA8PpffvpEzHJERD8iTmJTzLZjVHXEXrUo6P0Et0cBdhQASMPIFaxvPLPv8JhzzQM79n40ToRt+4c6Fs95YWf/h4OTi5trf3bf6rRJjhOpCV3eCrF2iQv4o9YlqjViYm3m2Xv4iHejwqzAlq2ySfOHd62YUytGp5wv/cNb/7H18JplLZmEOTZV7ukff2n34BMvHy6UlRACqorogLhEY1dkFTmzn68iruOdV1dQzFUQtgyZ+fDwdNlGNm0en7D/8sc9HYub2hfV33fdRXc/vuvRrr7GbNKUBpTCrHyqFgUxqwYqekzuwRTps0bze9SFEPwDM0mDX983XCgrKNQkjVwR1zyw/d3DY0TUN5yvr0nWJOUMTfVosp5hf6LqbrUFcSTOVxc7WL/Rv6wUgTBddv7mhvbmerPswIFKJ8TolLrpu923Pvzmtp6JdEJajqq2fsQy70yHPNlrLRH/nqmTEHshxVV4XUYCVJeWr+45PjHtpBMGwDYom5b9I+WDA8N1GQmlqDqreSrud7INgM7kAJEQlC+qjS/3ZZLyyS1H3uiZDPoGTKQUTMlJ0/QYFJzZczRqkT6GAyDLcebUmkPjViZpCMGze2mI1DHL91PzgYq8VlUlqNKO1ecVlDTleN6pzcjo6mechCPviWCG6um0fCDKMs1ql1wtEkAa7tJPxaD99h1T0Er2YZeGeJljqVbMbgaY5cE4uZMBs7sgV1W11sUIyNUZpSXP1MZP5yW9k4UDoPp51QbhafjAyXLcb2b1Z3nMnokx41Jm+anyLT98jJsRs4kUM3vqLD9VvqZxRoo73Q3g43rCx3yI36rB/nZ84CyVwPz/vQGc3TrOFNrgN7aB2dcxU9I564PPegP+O4dMxDM17pnpFDAKzyBixunoQ3sNssobuf5Fydo74QHtxVWAYdhfYqbK6oC1gsbrF8bKZY6+PTpz6RIyKPHeWOQNdvfz/wAqjmPbO2Wr6QAAAABJRU5ErkJggg==\">
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
			--danger: #dc3545;
			--danger-dark: #a41e2d;
			--danger-light: #fdf0f2;
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
		.form-error {
			margin: 0 0 16px;
			padding: 12px 14px;
			border: 1px solid #f5c2c7;
			border-left: 4px solid var(--danger);
			background: var(--danger-light);
			border-radius: 10px;
			text-align: left;
		}
		.form-error strong { display: block; font-size: 13px; color: var(--danger-dark); letter-spacing: 0.3px; }
		.form-error span { display: block; margin-top: 4px; font-size: 12px; color: var(--muted); line-height: 1.5; }
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
		.voucher-form button:disabled { opacity: 0.65; cursor: not-allowed; }
		.btn-spinner {
			display: none;
			width: 14px; height: 14px;
			margin-right: 8px;
			border: 2px solid rgba(255, 255, 255, 0.45);
			border-top-color: #ffffff;
			border-radius: 50%;
			vertical-align: -3px;
			animation: vspin 0.8s linear infinite;
		}
		button.busy .btn-spinner { display: inline-block; }
		@keyframes vspin { to { transform: rotate(360deg); } }
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
			WI-FI E-VOUCHER &middot; $year
		</div>
		</main>
		</body>
		</html>
	"

	exit 0
}

# Submit helper (progressive enhancement ONLY): while the server validates
# (multi-second backend round trip), show a spinner, relabel the button and
# disable it against double taps. Where JS is blocked (strict CPD), the form
# submits normally and correctness still holds: the backend claim is
# idempotent (rerequest), so a duplicate submit cannot double-spend time.
# ES5 syntax for old embedded webviews. Emitted once per page that has forms.
voucher_submit_js() {
	echo "<script>function voucherSubmit(f){var b=f.querySelector('button[type=submit]');if(!b||b.disabled){return false;}var t=b.querySelector('.btn-text');if(t){b.setAttribute('data-label',t.textContent);t.textContent='AUTHENTICATING…';}b.classList.add('busy');b.disabled=true;return true;}window.addEventListener('pageshow',function(){var bs=document.querySelectorAll('button.busy');for(var i=0;i<bs.length;i++){var b=bs[i];b.disabled=false;b.classList.remove('busy');var t=b.querySelector('.btn-text');if(t&&b.hasAttribute('data-label')){t.textContent=b.getAttribute('data-label');}}});</script>"
}

login_form() {
	# $voucher here is entity-encoded by libopennds parse_variables; safe to
	# reflect inside the quoted value attribute for re-serve preservation
	# (this is what keeps the code visible when an error is shown inline).
	# When $vtitle is set (failed attempt), an inline error banner renders
	# above the form: same page, no navigation, code preserved for correction.
	if [ -n "$vtitle" ]; then
		verrblock="
			<div class=\"form-error\" role=\"alert\">
				<strong>$vtitle</strong>
				<span>$vmsg</span>
			</div>
		"
	else
		verrblock=""
	fi
	vjs=$(voucher_submit_js)
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>CONNECT TO INTERNET</p>
			</div>
			$verrblock
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
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
				<button type=\"submit\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">CONNECT</span></button>
			</form>
			$vjs
			<div class="plan">
				<div class="plan-item"><strong>&#8369;5</strong><span>PRICE</span></div>
				<div class="plan-item"><strong>6 HOURS</strong><span>TIME</span></div>
				<div class="plan-item"><strong>10 Mbps</strong><span>SPEED</span></div>
			</div>
		</section>
	"
	verrblock=""
	vtitle=""
	vmsg=""
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
	vjs=$(voucher_submit_js)
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>VOUCHER RECEIVED</p>
			</div>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<input type=\"hidden\" name=\"voucher\" value=\"$voucher\">
				$customhtml
				<input type=\"hidden\" name=\"landing\" value=\"yes\">
				<button type=\"submit\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">Continue</span></button>
			</form>
			$vjs
			<p class=\"note\">If this page closes automatically, reopen your browser to continue.</p>
		</section>
	"
}

voucher_status_page() {
	# Direct path used by voucher_login(): pre-validate through the backend,
	# then authenticate and hand off to the clean portal entry.
	#
	# WHY HERE: this daemon honors the quotas carried IN the auth request and
	# may skip BinAuth on the FAS path, so validation MUST happen here before
	# the auth call — skipping that call on deny IS the enforcement (no call,
	# no grant possible: fail closed by construction). Same contract as the
	# BinAuth claimant (kept inline: self-contained ThemeSpec, no new files).
	#
	# WHY REDIRECT: the live custom status (with timer) is served at the clean
	# portal entry, so success hands the browser there instead of sitting on
	# the long preauth URL (which also leaks the voucher code in history).
	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — voucher value deliberately NOT added to userinfo.
	userinfo="$userinfo, stage2-validation"

	voucher_api_claim

	if [ "$vallow" = "1" ]; then
		binauth_custom="voucher=$voucher"
		encode_custom
		auth_log

		if [ "$ndsstatus" = "authenticated" ]; then
			voucher_redirect_page
		else
			voucher_deny_log
			voucher_error_text
			login_form
		fi
	else
		voucher_deny_log
		voucher_error_text
		login_form
	fi

	footer
}

voucher_resume_page() {
	# Codeless resume used by voucher_login() when resume=1 arrives with no
	# voucher: pre-validate through the backend /resume endpoint keyed by the
	# server-side client MAC, then authenticate and hand off to the clean
	# portal entry — exactly like the voucher path, but no code is ever
	# required, rendered, or logged. On DENY/no-match the auth call is SKIPPED
	# (fail closed); nomatch simply renders the plain login form so a fresh
	# voucher can still be entered.
	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — no voucher value exists on this path by construction.
	userinfo="$userinfo, stage2-resume"

	voucher_api_resume

	if [ "$vallow" = "1" ]; then
		binauth_custom="resume"
		encode_custom
		auth_log

		if [ "$ndsstatus" = "authenticated" ]; then
			voucher_redirect_page
		else
			voucher_deny_log
			voucher_error_text
			login_form
		fi
	else
		voucher_deny_log
		voucher_error_text
		login_form
	fi

	footer
}

# Best-effort masked deny audit: failure class + client MAC only.
# No voucher value, no PSK, no custom string, no backend detail.
voucher_deny_log() {
	if command -v logger >/dev/null 2>&1; then
		logger -t opennds-voucher "theme deny why=${vdenywhy:-unknown} mac=$clientmac" 2>/dev/null
	fi
}

# EAP-side voucher pre-validation for the ThemeSpec paths.
# Twin of the BinAuth claimant gates: strict allowlist, fail-closed config,
# strict reply shape, bounded numerics, ceil(remaining/60) capped at 1440.
# Sets: vallow (0/1), and on allow also session_length/upload_rate/
# download_rate/upload_quota/download_quota + rebuilt $quotas for auth_log.
# Never exits; never grants (granting is auth_log's job on allow only).
voucher_api_claim() {
	vallow=0
	vsession_min=0
	vup=0
	vdown=0
	# Failure class for the denied page (never a raw backend string):
	# badformat | noconfig | noreply | badreply | expired |
	# invalid | unknown | disabled | paused. Empty means allowed or unset.
	vdenywhy=""
	vcode=$(printf '%s' "$voucher" | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
	vcode=$(printf '%s' "$vcode" | tr 'a-z' 'A-Z')
	vok=1
	vlen=${#vcode}
	if [ "$vlen" -lt 4 ] || [ "$vlen" -gt 20 ]; then
		vok=0
	else
		case "$vcode" in
			*[!A-Z0-9-]*)
				vok=0
				;;
		esac
	fi
	vlen=""
	if [ "$vok" -ne 1 ]; then
		vcode=""
		vdenywhy="badformat"
		return
	fi
	if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
		VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
	fi
	vpsk=""
	vpskfile="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
	if [ -z "$VOUCHER_API_URL" ] || [ ! -f "$vpskfile" ]; then
		vcode=""
		vpskfile=""
		vdenywhy="noconfig"
		return
	fi
	vpsk=$(cat "$vpskfile" 2>/dev/null)
	vpskfile=""
	if [ -z "$vpsk" ]; then
		vcode=""
		vdenywhy="noconfig"
		return
	fi
	vresp=""
	if command -v uclient-fetch >/dev/null 2>&1; then
		vresp=$(uclient-fetch -q -T 5 -O - --post-data="voucher=$vcode&mac=$clientmac&ip=$clientip&token=&psk=$vpsk" "$VOUCHER_API_URL" 2>/dev/null)
	elif command -v wget >/dev/null 2>&1; then
		vresp=$(wget -q -T 5 -O - --post-data="voucher=$vcode&mac=$clientmac&ip=$clientip&token=&psk=$vpsk" "$VOUCHER_API_URL" 2>/dev/null)
	fi
	vpsk=""
	if [ -z "$vresp" ]; then
		vcode=""
		vdenywhy="noreply"
		return
	fi
	vline=$(printf '%s' "$vresp" | head -n 1)
	vdecision=$(printf '%s' "$vline" | awk '{print $1}')
	vnf=$(printf '%s' "$vline" | awk '{print NF}')
	vline=""
	if [ "$vdecision" != "ALLOW" ]; then
		# Keep only the documented backend reason vocabulary; anything else
		# (including empty/garbled replies) becomes a generic failure class.
		vwhy=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
		case "$vwhy" in
			invalid|unknown|disabled|paused|expired|bound)
				vdenywhy="$vwhy"
				;;
			*)
				vdenywhy="badreply"
				;;
		esac
		vwhy=""
		vresp=""
		vdecision=""
		vnf=""
		vcode=""
		return
	fi
	case "$vnf" in
		4|6)
			;;
		*)
			vresp=""
			vdecision=""
			vnf=""
			vcode=""
			vdenywhy="badreply"
			return
			;;
	esac
	vrem=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
	vup=$(printf '%s' "$vresp" | awk 'NR==1{print $3}')
	vdown=$(printf '%s' "$vresp" | awk 'NR==1{print $4}')
	vresp=""
	vdecision=""
	vnf=""
	case "$vrem" in ""|*[!0-9]*) vrem=""; ;; esac
	case "$vup" in ""|*[!0-9]*) vup=""; ;; esac
	case "$vdown" in ""|*[!0-9]*) vdown=""; ;; esac
	if [ -z "$vrem" ] || [ -z "$vup" ] || [ -z "$vdown" ]; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		vdenywhy="badreply"
		return
	fi
	if [ "${#vrem}" -gt 7 ] || [ "${#vup}" -gt 7 ] || [ "${#vdown}" -gt 7 ]; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		vdenywhy="badreply"
		return
	fi
	if [ "$vup" -gt 1000000 ] 2>/dev/null || [ "$vdown" -gt 1000000 ] 2>/dev/null; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		vdenywhy="badreply"
		return
	fi
	if [ "$vrem" -le 0 ] 2>/dev/null; then
		vrem=""
		vup=0
		vdown=0
		vcode=""
		vdenywhy="expired"
		return
	fi
	vsession_min=$(( (vrem + 59) / 60 ))
	if [ "$vsession_min" -gt 1440 ]; then
		vsession_min=1440
	fi
	vrem=""
	session_length="$vsession_min"
	upload_rate="$vup"
	download_rate="$vdown"
	upload_quota=0
	download_quota=0
	quotas="$session_length $upload_rate $download_rate $upload_quota $download_quota"
	vcode=""
	vallow=1
}

# Unified MAC state check for voucher_login() (ONE backend call serving the
# active/paused/expired branches, so CPD and browser entries share one
# decision). POSTs /session (MAC only, PSK in body) and sets vstate to
# active|paused|expired|none plus vremain (numeric remaining, else 0).
# Zero-balance paused/active degrades to expired (terminal page, never a
# resume that can only deny). Anything unrecognized or unreachable stays
# none (plain login). Read-only, code-free, never grants.
voucher_api_state_check() {
	vstate="none"
	vremain=0
	if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
		VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
	fi
	vpsk=""
	vpskfile="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
	case "$VOUCHER_API_URL" in
		*/claim)
			vsess_url="${VOUCHER_API_URL%/claim}/session"
			;;
		*)
			vsess_url=""
			;;
	esac
	if [ -z "$vsess_url" ] || [ ! -f "$vpskfile" ]; then
		vpskfile=""
		vsess_url=""
		return
	fi
	vpsk=$(cat "$vpskfile" 2>/dev/null)
	vpskfile=""
	if [ -z "$vpsk" ]; then
		vsess_url=""
		return
	fi
	vresp=""
	if command -v uclient-fetch >/dev/null 2>&1; then
		vresp=$(uclient-fetch -q -T 5 -O - --post-data="mac=$clientmac&psk=$vpsk" "$vsess_url" 2>/dev/null)
	elif command -v wget >/dev/null 2>&1; then
		vresp=$(wget -q -T 5 -O - --post-data="mac=$clientmac&psk=$vpsk" "$vsess_url" 2>/dev/null)
	fi
	vpsk=""
	vsess_url=""
	case "$vresp" in
		*'"active": true'*)
			vstate="active"
			;;
		*'"paused": true'*)
			vstate="paused"
			;;
		*'"expired": true'*)
			vstate="expired"
			;;
		*)
			vresp=""
			return
			;;
	esac
	vrem=$(printf '%s' "$vresp" | grep -o '"remaining_seconds": [0-9]*' | awk '{print $2}')
	vresp=""
	case "$vrem" in
		""|*[!0-9]*)
			vrem=""
			vremain=0
			return
			;;
	esac
	vremain="$vrem"
	vrem=""
	if [ "$vremain" -le 0 ] 2>/dev/null && [ "$vstate" != "expired" ]; then
		vstate="expired"
		vremain=0
	fi
}

# EAP-side resume pre-validation for voucher_resume_page().
# Twin of voucher_api_claim with NO voucher value anywhere: POSTs the /resume
# sibling (URL must end /claim; otherwise noconfig) with the server-side
# client MAC/IP only, and applies the same strict ALLOW-line shape, bounded
# numerics, and ceil(remaining/60) policy. DENY reasons: expired (banner),
# nomatch (plain login form, no error — nothing paused for this MAC), anything
# else (retry banner). Never exits; never grants.
voucher_api_resume() {
	vallow=0
	vsession_min=0
	vup=0
	vdown=0
	vdenywhy=""
	if [ -z "$VOUCHER_API_URL" ] && command -v uci >/dev/null 2>&1; then
		VOUCHER_API_URL=$(uci get opennds.@opennds[0].voucher_api_url 2>/dev/null)
	fi
	vpsk=""
	vpskfile="${VOUCHER_PSK_FILE:-/etc/opennds/voucher_psk}"
	case "$VOUCHER_API_URL" in
		*/claim)
			vresume_url="${VOUCHER_API_URL%/claim}/resume"
			;;
		*)
			vresume_url=""
			;;
	esac
	if [ -z "$vresume_url" ] || [ ! -f "$vpskfile" ]; then
		vpskfile=""
		vresume_url=""
		vdenywhy="noconfig"
		return
	fi
	vpsk=$(cat "$vpskfile" 2>/dev/null)
	vpskfile=""
	if [ -z "$vpsk" ]; then
		vresume_url=""
		vdenywhy="noconfig"
		return
	fi
	vresp=""
	if command -v uclient-fetch >/dev/null 2>&1; then
		vresp=$(uclient-fetch -q -T 5 -O - --post-data="mac=$clientmac&ip=$clientip&token=&psk=$vpsk" "$vresume_url" 2>/dev/null)
	elif command -v wget >/dev/null 2>&1; then
		vresp=$(wget -q -T 5 -O - --post-data="mac=$clientmac&ip=$clientip&token=&psk=$vpsk" "$vresume_url" 2>/dev/null)
	fi
	vpsk=""
	vresume_url=""
	if [ -z "$vresp" ]; then
		vdenywhy="noreply"
		return
	fi
	vline=$(printf '%s' "$vresp" | head -n 1)
	vdecision=$(printf '%s' "$vline" | awk '{print $1}')
	vnf=$(printf '%s' "$vline" | awk '{print NF}')
	vline=""
	if [ "$vdecision" != "ALLOW" ]; then
		vwhy=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
		case "$vwhy" in
			expired)
				vdenywhy="expired"
				;;
			nomatch|unknown|disabled|invalid)
				vdenywhy="nomatch"
				;;
			*)
				vdenywhy="badreply"
				;;
		esac
		vwhy=""
		vresp=""
		vdecision=""
		vnf=""
		return
	fi
	case "$vnf" in
		4|6)
			;;
		*)
			vresp=""
			vdecision=""
			vnf=""
			vdenywhy="badreply"
			return
			;;
	esac
	vrem=$(printf '%s' "$vresp" | awk 'NR==1{print $2}')
	vup=$(printf '%s' "$vresp" | awk 'NR==1{print $3}')
	vdown=$(printf '%s' "$vresp" | awk 'NR==1{print $4}')
	vresp=""
	vdecision=""
	vnf=""
	case "$vrem" in ""|*[!0-9]*) vrem=""; ;; esac
	case "$vup" in ""|*[!0-9]*) vup=""; ;; esac
	case "$vdown" in ""|*[!0-9]*) vdown=""; ;; esac
	if [ -z "$vrem" ] || [ -z "$vup" ] || [ -z "$vdown" ]; then
		vrem=""
		vup=0
		vdown=0
		vdenywhy="badreply"
		return
	fi
	if [ "${#vrem}" -gt 7 ] || [ "${#vup}" -gt 7 ] || [ "${#vdown}" -gt 7 ]; then
		vrem=""
		vup=0
		vdown=0
		vdenywhy="badreply"
		return
	fi
	if [ "$vup" -gt 1000000 ] 2>/dev/null || [ "$vdown" -gt 1000000 ] 2>/dev/null; then
		vrem=""
		vup=0
		vdown=0
		vdenywhy="badreply"
		return
	fi
	if [ "$vrem" -le 0 ] 2>/dev/null; then
		vrem=""
		vup=0
		vdown=0
		vdenywhy="expired"
		return
	fi
	vsession_min=$(( (vrem + 59) / 60 ))
	if [ "$vsession_min" -gt 1440 ]; then
		vsession_min=1440
	fi
	vrem=""
	session_length="$vsession_min"
	upload_rate="$vup"
	download_rate="$vdown"
	upload_quota=0
	download_quota=0
	quotas="$session_length $upload_rate $download_rate $upload_quota $download_quota"
	vallow=1
}

# Post-auth handoff (progressive enhancement ONLY): the grant is already
# decided before this renders, so this page carries no policy and no voucher
# data — it only moves the browser off the long preauth URL onto the clean
# portal entry (http://10.0.0.1/), which serves the live custom status
# (timer included) for the now-authenticated client. JS-on-load + meta-refresh
# carry the navigation (owner decision: no manual button); no-JS clients use
# meta-refresh. ES5 syntax for old embedded webviews.
voucher_redirect_page() {
	echo "<!DOCTYPE html>
		<html lang=\"en\">
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<meta name=\"color-scheme\" content=\"light\">
		<meta http-equiv=\"refresh\" content=\"0;url=http://10.0.0.1/\">
		<title>WI-FI E-VOUCHER</title>
		<link rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,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\">
		<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		html { background: #f4f6f8; }
		body { min-height: 100vh; font-family: Arial, Helvetica, sans-serif; background: #f4f6f8; color: #17202a; display: flex; align-items: center; justify-content: center; padding: 20px; }
		.container { width: 100%; max-width: 420px; }
		.card { background: #ffffff; border: 1px solid #e5e9ed; border-radius: 18px; padding: 30px 24px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06); text-align: center; }
		.brand-icon { width: 58px; height: 58px; margin: 0 auto 16px; border-radius: 16px; background: #1677ff; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: bold; }
		.brand h1 { font-size: 21px; letter-spacing: 0.5px; }
		.brand p { margin-top: 7px; font-size: 12px; color: #7b8794; letter-spacing: 1px; }
		.load-spinner { width: 34px; height: 34px; margin: 22px auto 6px; border: 3px solid #e5e9ed; border-top-color: #1677ff; border-radius: 50%; animation: vspin 0.8s linear infinite; }
		@keyframes vspin { to { transform: rotate(360deg); } }
		.note { margin-top: 16px; text-align: center; font-size: 11px; color: #7b8794; line-height: 1.5; }
		</style>
		</head>
		<body>
		<main class=\"container\">
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>CONNECTED</p>
			</div>
			<div class=\"load-spinner\"></div>
			<p class=\"note\">Taking you to your status&hellip;</p>
		</section>
		</main>
		<script>window.addEventListener(\"load\",function(){window.location.replace(\"http://10.0.0.1/\");});</script>
		</body>
		</html>
	"
}

# Paused-confirm page (universal paused entry for browsers AND CPD): the MAC
# owns a PAUSED voucher, so the bare code form would mislead — but no grant
# happens here either (explicit Resume tap still required, and nothing on
# this page navigates back to itself, so the redirect loop is structurally
# impossible). The Resume button posts fas+resume=1 INSIDE the FAS flow,
# which libopennds delivers as a genuine $resume variable however the client
# arrived; BinAuth then re-verifies the server-side MAC against the backend
# before any grant. The embedded code form (same target/validation as the
# login form) covers entering a DIFFERENT voucher; empty submit falls back
# to the plain login. No voucher value is rendered (none is known here).
voucher_paused_confirm_page() {
	if command -v logger >/dev/null 2>&1; then
		logger -t opennds-voucher "theme paused-confirm mac=$clientmac" 2>/dev/null
	fi
	case "$vremain" in
		""|*[!0-9]*)
			vptimer=""
			;;
		*)
			vptimer=$(printf "%02d:%02d:%02d" $((vremain/3600)) $(((vremain%3600)/60)) $((vremain%60)))
			;;
	esac
	if [ -n "$vptimer" ]; then
		vptimerblock="
			<div class=\"timer-section\">
				<span class=\"timer-label\">REMAINING (FROZEN)</span>
				<div class=\"timer\">$vptimer</div>
			</div>
		"
	else
		vptimerblock=""
	fi
	vptimer=""
	vjs=$(voucher_submit_js)
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>PAUSED SESSION FOUND</p>
			</div>
			$vptimerblock
			<p class=\"note\">Your remaining time is frozen. Press Resume to continue — no voucher code needed.</p>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<input type=\"hidden\" name=\"resume\" value=\"1\">
				<button type=\"submit\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">Resume</span></button>
			</form>
			$vjs
			<p class=\"note\">Or use a different voucher code:</p>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<label for=\"voucher\">Voucher Code</label>
				<input
					type=\"text\"
					id=\"voucher\"
					name=\"voucher\"
					placeholder=\"ABCD-1234\"
					autocomplete=\"off\"
					maxlength=\"20\"
					value=\"\"
				>
				<button type=\"submit\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">CONNECT</span></button>
			</form>
		</section>
	"
	vjs=""
	vptimerblock=""
}

# Terminal expired page (CPD entry): the MAC-bound voucher ran out, so neither
# a grant nor a misleading fresh login is right. The page states the fact and
# embeds the standard code form (same POST target/validation as login_form)
# for entering a DIFFERENT voucher; submitting it runs the normal claim flow.
# No grant, no voucher value rendered (none is known on this path anyway).
voucher_expired_page() {
	if command -v logger >/dev/null 2>&1; then
		logger -t opennds-voucher "theme expired-shown mac=$clientmac" 2>/dev/null
	fi
	vjs=$(voucher_submit_js)
	echo "
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>VOUCHER EXPIRED</p>
			</div>
			<div class=\"form-error\" role=\"alert\">
				<strong>TIME USED UP</strong>
				<span>The voucher time on this device has run out. Enter a different voucher code below to connect.</span>
			</div>
			<form class=\"voucher-form\" action=\"/opennds_preauth/\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<input type=\"hidden\" name=\"fas\" value=\"$fas\">
				<label for=\"voucher\">Voucher Code</label>
				<input
					type=\"text\"
					id=\"voucher\"
					name=\"voucher\"
					placeholder=\"ABCD-1234\"
					autocomplete=\"off\"
					maxlength=\"20\"
					value=\"\"
				>
				<button type=\"submit\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">CONNECT</span></button>
			</form>
			$vjs
			<div class=\"plan\">
				<div class=\"plan-item\"><strong>&#8369;5</strong><span>PRICE</span></div>
				<div class=\"plan-item\"><strong>6 HOURS</strong><span>TIME</span></div>
				<div class=\"plan-item\"><strong>10 Mbps</strong><span>SPEED</span></div>
			</div>
		</section>
	"
	vjs=""
}

# Shared failure vocabulary (single source for every deny path). Anti-enumeration
# rules (deliberate, do not "improve" without a security review):
# - unknown, disabled and malformed codes share ONE "not valid" message, so
#   responses never reveal whether a code exists or is admin-disabled;
# - transport/config failures share ONE retry message with no internals;
# - only expired (time genuinely exhausted) and paused/bound (session held
#   elsewhere — bound shares the paused text) get distinct text, since those
#   describe the holder's own voucher state rather than oracle answers.
# Sets $vtitle/$vmsg from $vdenywhy. Callers render them inline in login_form.
# "bound" (code claimed from a device other than the bound one) shares the
# IN USE text with "paused"; "nomatch" (resume with nothing paused for this
# MAC) renders NO banner — just the plain login form for a fresh code.
voucher_error_text() {
	case "$vdenywhy" in
		expired)
			vtitle="VOUCHER EXPIRED"
			vmsg="This voucher has expired or its included time has been used up."
			;;
		paused|bound)
			vtitle="VOUCHER IN USE"
			vmsg="This voucher is already active on another device."
			;;
		novoucher)
			vtitle="VOUCHER REQUIRED"
			vmsg="Please enter a voucher code to connect."
			;;
		nomatch)
			vtitle=""
			vmsg=""
			;;
		noreply|noconfig|badreply|"")
			vtitle="REQUEST FAILED"
			vmsg="Something went wrong or the request timed out. Please try again."
			;;
		*)
			vtitle="INVALID VOUCHER"
			vmsg="This voucher code is not valid. Check the code and try again."
			;;
	esac
}

landing_page() {
	originurl=$(printf "${originurl//%/\\x}")
	gatewayurl=$(printf "${gatewayurl//%/\\x}")
	configure_log_location
	. $mountpoint/ndscids/ndsinfo

	# Marker only — voucher value deliberately NOT added to userinfo.
	userinfo="$userinfo, stage2-validation"

	# Legacy fallback path, same enforcement as the direct path: a missing
	# voucher never reaches the auth call, and a denied/failed claim renders
	# the generic fail page with no grant possible.
	if [ -z "$voucher" ]; then
		vdenywhy="novoucher"
		voucher_deny_log
		voucher_error_text
		login_form
		footer
	fi

	voucher_api_claim

	if [ "$vallow" != "1" ]; then
		voucher_deny_log
		voucher_error_text
		login_form
		footer
	fi

	# Re-encode here (authoritative for this request) rather than trusting any
	# client-supplied custom field carried by the legacy two-step forms.
	binauth_custom="voucher=$voucher"
	encode_custom

	auth_log

	# No voucher / custom values rendered below (browser-privacy requirement).
	# Verification happens server-side: binauthlog.log + ndsctl json (see test proc).
	# Success hands off to the clean portal entry (same redirect page as the
	# direct path); failure reuses the generic inline fail block below.
	vjsl=$(voucher_submit_js)
	auth_fail="
		<section class=\"card\">
			<div class=\"brand\">
				<div class=\"brand-icon\">WiFi</div>
				<h1>WI-FI E-VOUCHER</h1>
				<p>REQUEST FAILED</p>
			</div>
			<p class=\"note\">Something went wrong or the request timed out. Please try again.</p>
			<form class=\"voucher-form\" action=\"http://$gatewayfqdn\" method=\"get\" onsubmit=\"return voucherSubmit(this)\">
				<button type=\"submit\"><span class=\"btn-spinner\"></span><span class=\"btn-text\">Try again</span></button>
			</form>
			$vjsl
		</section>
	"
	vjsl=""

	if [ "$ndsstatus" = "authenticated" ]; then
		voucher_redirect_page
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

# FAS dialogue variables for this theme. "voucher" is the login code and
# "resume" is the codeless-resume intent from the PAUSED portal button; both
# are what makes libopennds get_arguments/parse_variables populate $voucher
# and $resume.
additionalthemevars="voucher resume"

fasvarlist="$fasvarlist $additionalthemevars"

# Render-speed note: libopennds resolves an empty $client_zone by shelling out
# to get_client_interface.sh (ARP lookups plus ~1s ping waits per wireless
# interface on this CPU). This theme never displays the zone — detailed zone
# detection still runs per authentication inside binauth_log.sh — so preset it
# here to skip that per-page cost. Measured saving on EAP225: ~1.4 s/render.
client_zone="Wi-Fi"

# Do NOT set/encode binauth_custom here; voucher_status_page() (primary) and
# thankyou_page() (legacy fallback) set and encode it per-submission so each
# voucher value flows independently.
#binauth_custom=""
#encode_custom

# Log marker only (see privacy note above).
userinfo="$title, stage2-validation"
