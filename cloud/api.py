#!/usr/bin/env python3
"""Stage 2 voucher API — ONE validation function for Android CPD and Chrome.

Endpoints (same DB, same logic regardless of browser; browser never calls here,
only the EAP claimant does):
  POST /claim   form fields: voucher, mac, ip, token, psk
      -> text line:  ALLOW <remaining_secs> <up_kbps> <down_kbps>[ EVICT <oldmac>]
                     DENY <reason>
      (line format: busybox-sh parseable without jq; reasons are generic codes.
      Claim decisions are ALWAYS HTTP 200 so the EAP claimant has one parse
      path; PSK/routing failures are 4xx with a generic body.)
      A claim on a PAUSED voucher with remaining time RESUMES it (sets a fresh
      interval); same-MAC rerequest on a live interval keeps its start.
   POST /pause    form fields: mac, code?, why?, psk
       -> text line:  PAUSED <remaining_secs> | NOOP
       Idempotent freeze of the ACTIVE interval (used += elapsed, capped at the
       previous balance; resume_ts cleared; PAUSED, or EXPIRED at zero). The
       PAUSE button path and every BinAuth deauth callback both call it; double
       reports are safe no-ops. 200 + generic DENY only when the backend itself
       is down (EAP then falls back to its local view).
   POST /resume   form fields: mac, ip, token, psk
       -> text line:  ALLOW <remaining_secs> <up_kbps> <down_kbps>
                      DENY <reason>
       Codeless resume-by-MAC (same line shape as /claim so EAP parsers are
       reused; never carries the voucher code in either direction). The MAC
       MUST equal the voucher's bound_mac (server-side value supplied by the
       EAP daemon, never browser input): PAUSED flips to ACTIVE atomically
       (used_secs/total_secs preserved, fresh resume_ts); ACTIVE with the same
       MAC re-authenticates WITHOUT touching resume_ts (reconnect after a lost
       OpenNDS session never double-charges, never mints time). Anything else
       (unknown MAC, EXPIRED, DISABLED, zero remaining) denies. Atomic and
       idempotent: concurrent resumes serialize on the row lock and converge
       on one interval.
  GET  /session?code=<VOUCHER>   (header X-PSK or ?psk=) -> JSON answering the
      six Stage 3 questions (exists/active/paused/remaining/active-session/meta).
  GET|POST /session?mac=<MAC>    -> JSON {paused, active, remaining_seconds}
      for status display. NEVER includes the voucher code (display hint only;
      resuming still requires the code). POST variant keeps the PSK in the
      body (EAP uses POST).
   GET  /healthz -> ok

Admin dashboard (operator only, separate ADMIN_PSK; EAP key cannot admin):
   GET  /admin                 -> single-file dashboard UI (no data inside;
       needs the admin key, kept in browser sessionStorage, sent per call).
       Served openly ONLY as an empty shell; every data call below is gated.
   GET  /admin/api/stats       -> JSON {revenue_php, sold, unsold, by_tier,
       by_state, liability_secs, active_now}
   GET  /admin/api/vouchers?state=&q=&limit=&offset= -> JSON {total, rows[]}
       (rows carry live remaining + tier price; codes visible: admin channel)
   GET  /admin/api/events?limit= -> JSON {rows[]} latest decisions first
   POST /admin/api/create      -> {code, total_secs} (NEW row; tier implied)
   POST /admin/api/set_state   -> {code, state: NEW|DISABLED} (NEW only when
       never used; DISABLED from any state; used rows re-enable to PAUSED)
   POST /admin/api/release     -> {code} clears bound_mac (non-ACTIVE only;
       next claim rebinds; the documented operator escape hatch)
   POST /admin/api/extend      -> {code, add_secs} grows total_secs (cap 60d;
       EXPIRED flips to PAUSED so the bound device can resume)
   POST /admin/api/delete      -> {code} removes NEW+never-bound rows only
   Auth for all /admin/api/*: POST field psk, header X-PSK, or ?psk=
   (compare_digest; wrong/missing -> 403 JSON, generic). Every mutation
   writes an events row (decision ADMIN) as an audit trail.

Profit model (NO schema change): canonical RATE_TIERS map total_secs to
pesos (mirrors the portal price card). Sold = bound_mac IS NOT NULL
(first claim binds = sale). revenue = SUM(tier price over sold rows);
non-tier totals count as custom (tracked, priced unknown). Liability =
live remaining seconds across ACTIVE rows (settled, capped).

Public customer surface for browser SPAs (NO PSK by design — the voucher
code in the POST body IS the credential, same trust as the printed
voucher; codes never appear in URLs, logs, or responses beyond status):
   GET  /portal/rates   -> {tiers[]} (pure RATE_TIERS map, no DB)
   POST /portal/status  -> {code} -> {ok, active, paused,
       remaining_seconds, expired?} or {ok:false, error:not_valid}
       (unknown/disabled/malformed share not_valid; holder states render
       truthfully; read-only)
   POST /portal/pause   -> {code} -> {ok, paused, remaining_seconds}
       (pauses ACTIVE by code; always the same shape — no oracle)
   POST /portal/resume  -> {code} -> {ok, remaining_seconds, resumed?}
       (PAUSED flips to ACTIVE atomically, used/total preserved; ACTIVE
       returns a snapshot WITHOUT touching resume_ts — a browser can
       never mint time or a Wi-Fi grant; grants stay MAC-bound on EAP)
   All /portal/* are per-IP sliding-window rate-limited (30 req/min,
   10 code attempts/min; 429 + generic body) and CORS-gated to
   PORTAL_ORIGIN (comma-separated allowlist; preflight via OPTIONS;
   unlisted origins get no CORS headers). /admin/api/* answers CORS
   the same way for the admin SPA.

Backend selection (explicit; NEVER silent):
  DATABASE_URL set (postgres scheme) -> PostgreSQL ONLY via the `psycopg` v3
      driver (`pip install "psycopg[binary]"`). Driver missing, URL bad, or DB
      unreachable -> log a clear server-side error and answer every /claim
      with a generic DENY (fail closed). SQLite is never used in this mode.
  DATABASE_URL unset + VOUCHER_DB set -> SQLite explicit-dev backend
      (stand-in with equivalent semantics; never presented as PostgreSQL).
  Neither set -> refuse startup with a clear error.

Config env: DATABASE_URL, VOUCHER_DB, VOUCHER_PSK (required; compare_digest),
ADMIN_PSK (optional; enables /admin/api/* + marks dashboard live),
PORTAL_ORIGIN (optional; comma-separated CORS allowlist for browser SPAs
calling /portal/* and /admin/api/*; empty = no browser access),
HOST (default 127.0.0.1; production HOST=0.0.0.0 or the Ubuntu LAN IP — the API
is an internal EAP-to-Ubuntu service, never Internet-facing),
PORT (default 8080), UP_KBPS / DOWN_KBPS (default 0 = unlimited: the EAP
applies no per-client shaping when both are 0; set env values to cap speed).

Usage accounting (only ACTIVE time is consumed): an ACTIVE row with resume_ts
accrues on claim/pause transitions (capped at its previous balance, so reboot
gaps and duplicate claims can never corrupt or overdraw); reads never persist.
Same-MAC rerequest on a live interval keeps its start (resetting it would leak
free minutes). PAUSED rows resume on the next valid same-MAC claim or via
POST /resume (codeless, MAC-bound); EXPIRED/DISABLED deny. Binding policy is
STRICT: the first legitimate claim binds bound_mac, and once bound the voucher
NEVER silently rebinds — a different MAC presenting the code is denied (reason
"bound"), never moved; only an operator clears bound_mac. Known limit: an unrecorded outage
gap is charged up to the previous balance; outages are operator-visible,
credit back manually.
"""

import calendar
import hmac
import json
import logging
import os
import re
import threading
import time
import traceback
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, HTTPServer

CODE_RE = re.compile(r"^[A-Z0-9-]{4,20}$")

UP_KBPS = int(os.environ.get("UP_KBPS", "0"))
DOWN_KBPS = int(os.environ.get("DOWN_KBPS", "0"))

# Canonical rate tiers (MUST mirror the portal price card in theme_voucher.sh
# login_form()/voucher_expired_page(): total_secs -> PHP pesos. Sold revenue
# and inventory valuation derive from this map; no price column exists.
RATE_TIERS = {28800: 5, 64800: 10, 144000: 20, 230400: 30, 345600: 40,
              432000: 50, 720000: 80, 950400: 100, 1152000: 120}
MAX_TOTAL_SECS = 5184000  # 60-day cap for admin create/extend

# Public customer surface (/portal/*): browser-safe, NO PSK. Trust model:
# the voucher CODE is the credential (same as the printed voucher); the
# browser can only inspect/flip voucher STATE, never mint a Wi-Fi grant
# (grants stay MAC-bound on the EAP path). Unknown/disabled/malformed
# share one generic answer; only the holder's own states (NEW/ACTIVE/
# PAUSED/EXPIRED) render truthfully. Rate limits are per server instance
# (best-effort under multi-instance Railway).
PORTAL_RATE_WINDOW = 60.0
PORTAL_RATE_MAX = 30   # req/min/IP across all /portal/*
PORTAL_CODE_MAX = 10   # code attempts/min/IP (status/pause/resume)
_portal_hits = {}      # ip -> {"all": deque, "code": deque}
_portal_lock = threading.Lock()


def portal_origins():
    """Allowed CORS origins for browser SPAs (comma-separated env)."""
    return [o.strip() for o in os.environ.get("PORTAL_ORIGIN", "").split(",")
            if o.strip()]


def cors_headers(handler):
    """Echo a whitelisted Origin, else no CORS headers (fail closed)."""
    origin = handler.headers.get("Origin", "")
    if origin and origin in portal_origins():
        return {"Access-Control-Allow-Origin": origin, "Vary": "Origin"}
    return {}


def portal_limited(ip):
    """Sliding-window gate for /portal/* (no-code calls). True = refuse."""
    now = time.monotonic()
    with _portal_lock:
        ent = _portal_hits.get(ip)
        if ent is None:
            ent = _portal_hits[ip] = {"all": deque(), "code": deque()}
        dq = ent["all"]
        while dq and now - dq[0] > PORTAL_RATE_WINDOW:
            dq.popleft()
        if len(dq) >= PORTAL_RATE_MAX:
            return True
        dq.append(now)
        _prune_locked(now)
        return False


def portal_code_limited(ip):
    """Stricter bucket for code-attempt calls. True = refuse."""
    now = time.monotonic()
    with _portal_lock:
        ent = _portal_hits.get(ip)
        if ent is None:
            ent = _portal_hits[ip] = {"all": deque(), "code": deque()}
        for dq in (ent["all"], ent["code"]):
            while dq and now - dq[0] > PORTAL_RATE_WINDOW:
                dq.popleft()
        if len(ent["all"]) >= PORTAL_RATE_MAX \
                or len(ent["code"]) >= PORTAL_CODE_MAX:
            return True
        ent["all"].append(now)
        ent["code"].append(now)
        _prune_locked(now)
        return False


def _prune_locked(now):
    if len(_portal_hits) > 4096:
        dead = [k for k, v in _portal_hits.items()
                if not v["all"] and not v["code"]
                or (v["all"] and now - v["all"][-1] > PORTAL_RATE_WINDOW
                    and v["code"]
                    and now - v["code"][-1] > PORTAL_RATE_WINDOW)]
        for k in dead[:1024]:
            _portal_hits.pop(k, None)

DATABASE_URL = os.environ.get("DATABASE_URL", "")
VOUCHER_DB = os.environ.get("VOUCHER_DB", "")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))

log = logging.getLogger("voucher-api")

# Explicit-dev SQLite DDL only. It mirrors backend/schema.sql (production,
# installed separately by the operator — see its header) for local
# development/tests. The two are kept semantically identical by review
# (and proven by backend/test_pg.py loading schema.sql verbatim), never by
# silent substitution: with DATABASE_URL set, this SQLite DDL is dead code.
SQLITE_DDL = """
CREATE TABLE IF NOT EXISTS vouchers (
    code TEXT PRIMARY KEY,
    total_secs INTEGER NOT NULL DEFAULT 21600 CHECK (total_secs >= 0),
    used_secs INTEGER NOT NULL DEFAULT 0 CHECK (used_secs >= 0),
    state TEXT NOT NULL DEFAULT 'NEW'
        CHECK (state IN ('NEW','ACTIVE','PAUSED','EXPIRED','DISABLED')),
    bound_mac TEXT,
    last_ip TEXT,
    last_token TEXT,
    first_seen TEXT,
    last_auth TEXT,
    resume_ts TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    code TEXT NOT NULL,
    mac TEXT, ip TEXT, token TEXT,
    decision TEXT NOT NULL,
    reason TEXT NOT NULL,
    remaining_secs INTEGER,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_events_code ON events (code);
CREATE INDEX IF NOT EXISTS idx_vouchers_bound ON vouchers (bound_mac);
"""


class BackendError(Exception):
    """Raised for any DB unavailability/misconfiguration. Callers deny."""


class DB:
    """Minimal placeholder/transaction adapter.

    kind == "pg":     %s placeholders, SELECT ... FOR UPDATE, TIMESTAMPTZ.
    kind == "sqlite":  ? placeholders, BEGIN IMMEDIATE, TEXT timestamps.
    """

    def __init__(self, kind, conn):
        self.kind = kind
        self.conn = conn

    @classmethod
    def connect(cls):
        if DATABASE_URL:
            try:
                import psycopg
                from psycopg.rows import dict_row
            except ImportError:
                raise BackendError("db-driver-missing")
            try:
                conn = psycopg.connect(DATABASE_URL, row_factory=dict_row,
                                       connect_timeout=5)
            except Exception as exc:
                raise BackendError("db-unavailable: %s" % type(exc).__name__)
            return cls("pg", conn)
        if VOUCHER_DB:
            import sqlite3
            conn = sqlite3.connect(VOUCHER_DB)
            conn.row_factory = sqlite3.Row
            conn.isolation_level = None  # explicit transactions below
            conn.executescript(SQLITE_DDL)
            return cls("sqlite", conn)
        raise BackendError("db-unconfigured")

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass

    def _q(self, sql):
        if self.kind == "sqlite":
            sql = sql.replace("%s", "?")
        return sql

    def execute(self, sql, params=()):
        cur = self.conn.cursor()
        cur.execute(self._q(sql), params)
        return cur

    def row(self, sql, params=()):
        r = self.execute(sql, params).fetchone()
        return dict(r) if r is not None else None

    def now_sql(self):
        return "now()" if self.kind == "pg" else "datetime('now')"

    def stamp_sql(self):
        # Deterministic resume_ts write from an explicit epoch (tests and
        # callers pass now=); DB clock otherwise. pg stores timestamptz.
        return "to_timestamp(%s)" if self.kind == "pg" else "datetime(%s, 'unixepoch')"

    def stamp_param(self, now):
        now = float(now)
        return now if self.kind == "pg" else int(now)

    def begin_claim(self):
        # Atomic-claim guard: pg row lock; sqlite write-transaction lock.
        if self.kind == "sqlite":
            self.execute("BEGIN IMMEDIATE")

    def commit(self):
        self.conn.commit()

    def rollback(self):
        try:
            self.conn.rollback()
        except Exception:
            pass


def iso(value):
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat()
    text = str(value).strip()
    if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", text):
        return text.replace(" ", "T") + "Z"
    return text


def normalize(code):
    return (code or "").strip().upper()


def normalize_mac(mac):
    # MACs arrive in mixed case (portal logs show lowercase); canonical upper.
    # Lookups compare case-insensitively too, so legacy rows keep matching.
    return (mac or "").strip().upper()


def to_epoch(value):
    """resume_ts (pg timestamptz / sqlite UTC text / epoch) -> float or None."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if hasattr(value, "timestamp"):
        try:
            return float(value.timestamp())
        except Exception:
            return None
    text = str(value).strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S",
                "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return float(calendar.timegm(time.strptime(text, fmt)))
        except ValueError:
            continue
    try:
        return float(text)
    except ValueError:
        return None


def _settle(row, now):
    """Pure computation, no writes: (used, remaining) after accruing any open
    ACTIVE interval, capped so elapsed can never exceed the previous balance
    (bounds reboot-gap/post-mortem claims; never corrupts, never negative).
    Times are whole seconds (EAP session_length=ceil(remaining/60))."""
    total = int(row["total_secs"] or 0)
    used = int(row["used_secs"] or 0)
    prev = max(0, total - used)
    if row["state"] == "ACTIVE":
        resume = to_epoch(row.get("resume_ts"))
        if resume is not None:
            used = used + int(min(max(0.0, now - resume), prev))
    return used, max(0, total - used)


def log_event(db, code, mac, ip, token, decision, reason, remaining):
    db.execute(
        "INSERT INTO events (code, mac, ip, token, decision, reason,"
        " remaining_secs) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (code, mac, ip, token, decision, reason, remaining),
    )


def claim_voucher(db, code, mac="", ip="", token="", now=None):
    """Single authoritative validation function. Writes vouchers+events.

    now is epoch seconds (tests pass fixed values; default wall clock).
    Accounting model: an ACTIVE row with resume_ts accrues on read (settle,
    capped); a new claim starts/resumes an interval (resume_ts=now) EXCEPT a
    same-MAC rerequest on a live interval, which keeps its resume_ts (resetting
    it would discard accrued time = free minutes). Returned remaining_secs
    drives EAP session_length=ceil(remaining/60). evict is always None (kept
    for line-format compatibility; strict binding never moves a voucher, so no
    EVICT is ever emitted). A claim from a MAC other than the bound one is
    DENIED with reason "bound" — codeless resume for the bound MAC lives in
    resume_voucher()/POST /resume. Caller MUST hold backend errors
    as deny; this function assumes a live db.
    """
    now = time.time() if now is None else float(now)
    code = normalize(code)
    mac = normalize_mac(mac)
    if not CODE_RE.match(code):
        log_event(db, code or "?", mac, ip, token, "DENY", "invalid", None)
        db.commit()
        return {"decision": "DENY", "reason": "invalid", "remaining": 0,
                "evict": None}
    db.begin_claim()
    try:
        row = _locked_row(db, "code=%s", (code,))
        if row is None:
            log_event(db, code, mac, ip, token, "DENY", "unknown", 0)
            db.commit()
            return {"decision": "DENY", "reason": "unknown", "remaining": 0,
                    "evict": None}
        used, remaining = _settle(row, now)
        state = row["state"]
        if state == "DISABLED":
            db.execute("UPDATE vouchers SET used_secs=%s WHERE code=%s",
                       (used, code))
            log_event(db, code, mac, ip, token, "DENY", "disabled", remaining)
            db.commit()
            return {"decision": "DENY", "reason": "disabled",
                    "remaining": remaining, "evict": None}
        if remaining <= 0 or state == "EXPIRED":
            db.execute("UPDATE vouchers SET used_secs=%s, resume_ts=NULL,"
                       " state='EXPIRED' WHERE code=%s", (used, code))
            log_event(db, code, mac, ip, token, "DENY", "expired", 0)
            db.commit()
            return {"decision": "DENY", "reason": "expired", "remaining": 0,
                    "evict": None}
        bound = (row["bound_mac"] or "").upper()
        evict = None
        nowfn = db.now_sql()
        if bound and mac and bound != mac:
            # Strict binding: a bound voucher never moves. A different MAC
            # presenting the code is denied (no state change, no rebind);
            # the bound device resumes codeless via POST /resume.
            log_event(db, code, mac, ip, token, "DENY", "bound", remaining)
            db.commit()
            return {"decision": "DENY", "reason": "bound",
                    "remaining": remaining, "evict": None}
        start_interval = (row.get("resume_ts") is None or state != "ACTIVE")
        if state == "PAUSED":
            reason = "resumed"
        else:
            reason = "rerequest" if bound == mac and bound else "fresh"
        if start_interval:
            db.execute(
                "UPDATE vouchers SET state='ACTIVE', used_secs=%s,"
                " bound_mac=%s, last_ip=%s, last_token=%s,"
                " resume_ts=" + db.stamp_sql() + ","
                " first_seen=COALESCE(first_seen," + nowfn + "),"
                " last_auth=" + nowfn + " WHERE code=%s",
                (used, mac or bound, ip, token, db.stamp_param(now),
                 code))
        else:
            db.execute(
                "UPDATE vouchers SET used_secs=%s, last_ip=%s,"
                " last_token=%s, last_auth=" + nowfn + " WHERE code=%s",
                (used, ip, token, code))
        log_event(db, code, mac, ip, token, "ALLOW", reason, remaining)
        db.commit()
        return {"decision": "ALLOW", "reason": reason, "remaining": remaining,
                "evict": evict}
    except Exception:
        db.rollback()
        raise


def pause_voucher(db, mac="", code="", why="deauth", now=None):
    """Freeze an ACTIVE interval: accrue elapsed (capped), clear resume_ts,
    flip to PAUSED (or EXPIRED at zero). Fully idempotent: repeated calls and
    calls with nothing active are silent no-ops (no event row) so the PAUSE
    button path and the BinAuth deauth callback can both fire safely.
    Returns dict with paused bool + live remaining. Never raises for
    not-found (only for real DB errors, which callers hold as deny).
    """
    now = time.time() if now is None else float(now)
    mac = normalize_mac(mac)
    code = normalize(code)
    if code and not CODE_RE.match(code):
        code = ""
    if why not in ("idle", "timeout", "client", "shutdown", "ndsctl",
                   "deauth"):
        why = "deauth"
    db.begin_claim()
    try:
        row = None
        if code:
            row = _locked_row(db, "code=%s", (code,))
            if row is None or row["state"] != "ACTIVE":
                row = None
        if row is None and mac:
            row = _locked_row(
                db, "UPPER(bound_mac)=%s AND state='ACTIVE'", (mac,))
        if row is None:
            db.commit()
            return {"paused": False, "reason": "noop", "remaining": 0}
        used, remaining = _settle(row, now)
        new_state = "PAUSED" if remaining > 0 else "EXPIRED"
        db.execute("UPDATE vouchers SET used_secs=%s, resume_ts=NULL,"
                   " state=%s WHERE code=%s", (used, new_state, row["code"]))
        log_event(db, row["code"], mac, "", "", new_state,
                  "paused-" + why if new_state == "PAUSED" else "exhausted",
                  remaining)
        db.commit()
        return {"paused": True, "reason": new_state.lower(),
                "remaining": remaining, "code": row["code"]}
    except Exception:
        db.rollback()
        raise


MAC_RE = re.compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")


def resume_voucher(db, mac="", ip="", token="", now=None):
    """Codeless resume-by-MAC (POST /resume). The MAC is the identity: it must
    exactly equal the voucher's bound_mac (normalized upper-case; callers pass
    the server-side daemon MAC, never browser input). No voucher code travels
    in either direction — the response is the same ALLOW/DENY grant line as
    /claim so EAP parsers are reused, and it deliberately carries no code.

    - PAUSED + remaining > 0 -> ACTIVE atomically: used_secs/total_secs
      preserved, fresh resume_ts=now, last_ip/last_auth refreshed. This is the
      Resume-button and reconnect path; no code is required or accepted.
    - ACTIVE + same MAC (reconnect with a lost OpenNDS session) -> ALLOW with
      live remaining WITHOUT touching resume_ts: no new interval, no extra
      time, no double-charge. (A corrupt ACTIVE row with NULL resume_ts starts
      a fresh interval instead of denying, so the client is never bricked.)
    - remaining <= 0 -> EXPIRED flip + DENY expired. Unknown MAC, NEW (never
      bound), EXPIRED, DISABLED -> DENY nomatch/expired. A randomized-MAC
      device whose MAC differs from bound_mac simply matches nothing and falls
      back to normal voucher login.

    Atomic (row lock) and idempotent: concurrent resumes serialize; the second
    sees the ACTIVE interval the first created and re-authenticates on it.
    """
    now = time.time() if now is None else float(now)
    mac = normalize_mac(mac)
    if not MAC_RE.match(mac):
        log_event(db, "?", mac, ip, token, "DENY", "invalid", 0)
        db.commit()
        return {"decision": "DENY", "reason": "invalid", "remaining": 0,
                "evict": None}
    db.begin_claim()
    try:
        row = _locked_row(
            db, "UPPER(bound_mac)=%s AND state IN ('ACTIVE','PAUSED')"
            " ORDER BY last_auth DESC LIMIT 1", (mac,))
        # pg appends FOR UPDATE inside _locked_row; sqlite serializes via the
        # BEGIN IMMEDIATE in begin_claim. Most-recent binding wins if one MAC
        # ever holds two vouchers.
        if row is None:
            log_event(db, "?", mac, ip, token, "DENY", "nomatch", 0)
            db.commit()
            return {"decision": "DENY", "reason": "nomatch", "remaining": 0,
                    "evict": None}
        used, remaining = _settle(row, now)
        code = row["code"]
        nowfn = db.now_sql()
        if remaining <= 0:
            db.execute("UPDATE vouchers SET used_secs=%s, resume_ts=NULL,"
                       " state='EXPIRED' WHERE code=%s", (used, code))
            log_event(db, code, mac, ip, token, "DENY", "expired", 0)
            db.commit()
            return {"decision": "DENY", "reason": "expired", "remaining": 0,
                    "evict": None}
        if row["state"] == "PAUSED":
            db.execute(
                "UPDATE vouchers SET state='ACTIVE', used_secs=%s,"
                " last_ip=%s, last_token=%s,"
                " resume_ts=" + db.stamp_sql() + ","
                " last_auth=" + nowfn + " WHERE code=%s",
                (used, ip, token, db.stamp_param(now), code))
            reason = "resumed"
        elif row.get("resume_ts") is None:
            # Corrupt ACTIVE (no anchor): start a fresh interval now rather
            # than bricking the client; gap before now is operator-visible.
            db.execute(
                "UPDATE vouchers SET used_secs=%s, last_ip=%s, last_token=%s,"
                " resume_ts=" + db.stamp_sql() + ","
                " last_auth=" + nowfn + " WHERE code=%s",
                (used, ip, token, db.stamp_param(now), code))
            reason = "resumed"
        else:
            # Live interval re-auth (reconnect): accrue, keep the anchor.
            db.execute(
                "UPDATE vouchers SET used_secs=%s, last_ip=%s, last_token=%s,"
                " last_auth=" + nowfn + " WHERE code=%s",
                (used, ip, token, code))
            reason = "rerequest"
        log_event(db, code, mac, ip, token, "ALLOW", reason, remaining)
        db.commit()
        return {"decision": "ALLOW", "reason": reason, "remaining": remaining,
                "evict": None}
    except Exception:
        db.rollback()
        raise


def _locked_row(db, where, params):
    if db.kind == "pg":
        return db.row("SELECT * FROM vouchers WHERE " + where + " FOR UPDATE",
                      params)
    return db.row("SELECT * FROM vouchers WHERE " + where, params)


def session_info(db, code, now=None):
    """Answer the six Stage 3 questions for one voucher code. Read-only:
    live-accrues nothing, persists nothing (accrual happens only on
    claim/pause transitions)."""
    now = time.time() if now is None else float(now)
    code = normalize(code)
    row = db.row("SELECT * FROM vouchers WHERE code=%s", (code,))
    if row is None:
        return {"exists": False, "active": False, "paused": False,
                "remaining_seconds": 0, "active_session": None, "meta": {}}
    _, remaining = _settle(row, now)
    state = row["state"]
    return {
        "exists": True,
        "active": state == "ACTIVE" and remaining > 0,
        "paused": state == "PAUSED",
        "remaining_seconds": remaining,
        "active_session": {"mac": row["bound_mac"], "ip": row["last_ip"],
                           "since": iso(row["first_seen"]),
                           "last_auth": iso(row["last_auth"])}
        if state in ("ACTIVE", "PAUSED") else None,
        "meta": {"state": state, "total_secs": row["total_secs"],
                 "used_secs": row["used_secs"]},
    }


def session_info_by_mac(db, mac, now=None):
    """Paused/active display lookup keyed by device MAC. Deliberately returns
    NO voucher code (display hint only; resuming still requires the code).
    Read-only like session_info. The "expired" flag lets entry points (CPD
    included) show a terminal EXPIRED page for a MAC whose latest voucher ran
    out, instead of a misleading fresh login; DISABLED stays unflagged
    (generic login, anti-enumeration)."""
    now = time.time() if now is None else float(now)
    mac = normalize_mac(mac)
    if not mac:
        return {"paused": False, "active": False, "remaining_seconds": 0,
                "expired": False}
    row = db.row("SELECT * FROM vouchers WHERE UPPER(bound_mac)=%s"
                 " AND state IN ('ACTIVE','PAUSED')"
                 " ORDER BY last_auth DESC LIMIT 1", (mac,))
    if row is None:
        exp = db.row("SELECT 1 FROM vouchers WHERE UPPER(bound_mac)=%s"
                     " AND state='EXPIRED' ORDER BY last_auth DESC LIMIT 1",
                     (mac,))
        return {"paused": False, "active": False, "remaining_seconds": 0,
                "expired": exp is not None}
    _, remaining = _settle(row, now)
    state = row["state"]
    return {"paused": state == "PAUSED",
            "active": state == "ACTIVE" and remaining > 0,
            "remaining_seconds": remaining,
            "expired": False}


def tier_price(total_secs):
    """Portal tier price in PHP for a total_secs value, or None (custom)."""
    try:
        return RATE_TIERS.get(int(total_secs))
    except (TypeError, ValueError):
        return None


def admin_ok(given):
    """Admin gate: separate key from the EAP path, live-read for tests."""
    psk = os.environ.get("ADMIN_PSK", "")
    return bool(psk) and hmac.compare_digest(str(given or ""), psk)


def _dicts(cur):
    return [dict(r) for r in cur.fetchall()]


def portal_rates():
    """Public tier list (pure function of RATE_TIERS, no DB). Shape matches
    what the React SPA renders; labels mirror the EAP price card."""
    labels = {28800: "8 Hours", 64800: "18 Hours",
              144000: "1 Day 16 Hours", 230400: "2 Days 16 Hours",
              345600: "4 Days", 432000: "5 Days",
              720000: "8 Days 8 Hours", 950400: "11 Days",
              1152000: "13 Days 8 Hours"}
    return {"tiers": [
        {"total_secs": t, "price_php": p,
         "label": labels.get(t, "%ds" % t)}
        for t, p in sorted(RATE_TIERS.items())]}


def _portal_row(db, code):
    """Shared lookup: None for malformed/unknown/DISABLED (generic answer),
    else the settled row. Callers render holder states truthfully."""
    code = normalize(code)
    if not CODE_RE.match(code):
        return None
    row = db.row("SELECT * FROM vouchers WHERE code=%s", (code,))
    if row is None or row["state"] == "DISABLED":
        return None
    return row


def portal_status(db, code, now=None):
    """Browser status-by-code. Read-only. Generic not_valid for anything
    that is not the holder's own voucher."""
    now = time.time() if now is None else float(now)
    code = normalize(code)
    row = _portal_row(db, code)
    if row is None:
        return {"ok": False, "error": "not_valid"}
    _, remaining = _settle(row, now)
    state = row["state"]
    if state == "EXPIRED" or remaining <= 0:
        return {"ok": True, "active": False, "paused": False,
                "remaining_seconds": 0, "expired": True}
    return {"ok": True, "active": state == "ACTIVE",
            "paused": state == "PAUSED", "remaining_seconds": remaining,
            "expired": False}


def resume_by_code(db, code, now=None):
    """Browser resume-by-code: PAUSED + remaining -> ACTIVE atomically
    (used/total preserved, fresh resume_ts). ACTIVE + remaining -> ok
    snapshot WITHOUT touching resume_ts (a browser can never mint time).
    NEW/unknown/disabled -> generic not_valid; exhausted -> expired flip."""
    now = time.time() if now is None else float(now)
    code = normalize(code)
    if not CODE_RE.match(code):
        return {"ok": False, "error": "not_valid"}
    db.begin_claim()
    try:
        row = _locked_row(db, "code=%s", (code,))
        if row is None or row["state"] == "DISABLED":
            log_event(db, code, "", "", "", "DENY", "unknown", 0)
            db.commit()
            return {"ok": False, "error": "not_valid"}
        used, remaining = _settle(row, now)
        if remaining <= 0 or row["state"] == "EXPIRED":
            db.execute("UPDATE vouchers SET used_secs=%s, resume_ts=NULL,"
                       " state='EXPIRED' WHERE code=%s", (used, code))
            log_event(db, code, "", "", "", "DENY", "expired", 0)
            db.commit()
            return {"ok": False, "error": "expired"}
        if row["state"] == "NEW":
            # Holder's own fresh voucher: truthful snapshot, no state
            # change (starting a session needs the Wi-Fi/EAP claim path).
            db.commit()
            return {"ok": True, "active": False, "paused": False,
                    "remaining_seconds": remaining, "expired": False,
                    "resumed": False}
        nowfn = db.now_sql()
        if row["state"] == "PAUSED":
            db.execute(
                "UPDATE vouchers SET state='ACTIVE', used_secs=%s,"
                " resume_ts=" + db.stamp_sql() + ","
                " last_auth=" + nowfn + " WHERE code=%s",
                (used, db.stamp_param(now), code))
            log_event(db, code, "", "", "", "ALLOW", "resumed", remaining)
            db.commit()
            return {"ok": True, "remaining_seconds": remaining,
                    "resumed": True}
        db.commit()  # ACTIVE: snapshot only, anchor untouched
        return {"ok": True, "remaining_seconds": remaining,
                "resumed": False}
    except Exception:
        db.rollback()
        raise


def admin_stats(db, now=None):
    """Profit + inventory snapshot. Read-only. Portable SQL only."""
    now = time.time() if now is None else float(now)
    by_state = {r["state"]: r["n"] for r in _dicts(db.execute(
        "SELECT state, COUNT(*) AS n FROM vouchers GROUP BY state"))}
    sold = _dicts(db.execute(
        "SELECT total_secs, COUNT(*) AS n FROM vouchers"
        " WHERE bound_mac IS NOT NULL GROUP BY total_secs"))
    unsold = _dicts(db.execute(
        "SELECT total_secs, COUNT(*) AS n FROM vouchers"
        " WHERE bound_mac IS NULL GROUP BY total_secs"))
    by_tier, revenue, sold_n, unsold_n = [], 0, 0, 0
    buckets = {}
    for r in sold + unsold:
        b = buckets.setdefault(int(r["total_secs"]),
                               {"sold": 0, "unsold": 0})
        buckets[int(r["total_secs"])] = b
    for r in sold:
        buckets[int(r["total_secs"])]["sold"] = int(r["n"])
    for r in unsold:
        buckets[int(r["total_secs"])]["unsold"] = int(r["n"])
    for total in sorted(buckets):
        b = buckets[total]
        price = tier_price(total)
        rev = (price or 0) * b["sold"]
        revenue += rev
        sold_n += b["sold"]
        unsold_n += b["unsold"]
        by_tier.append({"total_secs": total, "price_php": price,
                        "sold": b["sold"], "unsold": b["unsold"],
                        "revenue_php": rev})
    liability = 0
    active_now = 0
    for r in _dicts(db.execute(
            "SELECT * FROM vouchers WHERE state='ACTIVE'")):
        _, remaining = _settle(r, now)
        if remaining > 0:
            active_now += 1
            liability += remaining
    return {"revenue_php": revenue, "sold": sold_n, "unsold": unsold_n,
            "by_tier": by_tier, "by_state": by_state,
            "liability_secs": liability, "active_now": active_now}


def admin_list(db, state="", q="", limit=50, offset=0, now=None):
    """Paginated voucher rows with live remaining + tier price. Read-only."""
    now = time.time() if now is None else float(now)
    try:
        limit = min(200, max(1, int(limit)))
    except (TypeError, ValueError):
        limit = 50
    try:
        offset = max(0, int(offset))
    except (TypeError, ValueError):
        offset = 0
    where, params = [], []
    state = (state or "").strip().upper()
    if state:
        if state not in ("NEW", "ACTIVE", "PAUSED", "EXPIRED", "DISABLED"):
            return {"total": 0, "rows": []}
        where.append("state=%s")
        params.append(state)
    q = (q or "").strip().upper()
    if q:
        where.append("UPPER(code) LIKE %s")
        params.append("%" + q.replace("%", "").replace("_", "") + "%")
    clause = ("WHERE " + " AND ".join(where)) if where else ""
    total = db.row("SELECT COUNT(*) AS n FROM vouchers " + clause,
                   tuple(params))["n"]
    rows = []
    for r in _dicts(db.execute(
            "SELECT * FROM vouchers " + clause +
            " ORDER BY code ASC LIMIT %s OFFSET %s",
            tuple(params) + (limit, offset))):
        _, remaining = _settle(r, now)
        rows.append({
            "code": r["code"], "state": r["state"],
            "total_secs": r["total_secs"], "used_secs": r["used_secs"],
            "remaining_secs": remaining,
            "price_php": tier_price(r["total_secs"]),
            "bound_mac": r["bound_mac"], "last_ip": r["last_ip"],
            "first_seen": iso(r["first_seen"]),
            "last_auth": iso(r["last_auth"])})
    return {"total": int(total), "rows": rows}


def admin_events(db, limit=50):
    """Latest event rows first (audit/activity feed). Read-only."""
    try:
        limit = min(200, max(1, int(limit)))
    except (TypeError, ValueError):
        limit = 50
    return {"rows": [{
        "id": r["id"], "code": r["code"], "mac": r["mac"],
        "decision": r["decision"], "reason": r["reason"],
        "remaining_secs": r["remaining_secs"],
        "created_at": iso(r["created_at"])} for r in _dicts(db.execute(
            "SELECT * FROM events ORDER BY id DESC LIMIT %s", (limit,)))]}


def admin_create(db, code, total_secs):
    """New NEW row (unsold inventory). Tier implied by total_secs."""
    code = normalize(code)
    try:
        total_secs = int(total_secs)
    except (TypeError, ValueError):
        return {"ok": False, "error": "bad_secs"}
    if not CODE_RE.match(code):
        return {"ok": False, "error": "bad_code"}
    if total_secs <= 0 or total_secs > MAX_TOTAL_SECS:
        return {"ok": False, "error": "bad_secs"}
    db.begin_claim()
    try:
        if _locked_row(db, "code=%s", (code,)) is not None:
            db.commit()
            return {"ok": False, "error": "exists"}
        db.execute("INSERT INTO vouchers (code,total_secs,used_secs,state)"
                   " VALUES (%s,%s,0,'NEW')", (code, total_secs))
        log_event(db, code, "", "", "", "ADMIN", "create", total_secs)
        db.commit()
        return {"ok": True, "code": code, "total_secs": total_secs,
                "price_php": tier_price(total_secs)}
    except Exception:
        db.rollback()
        raise


def admin_set_state(db, code, state):
    """DISABLED from any state; NEW only when never used (else deny);
    re-enable of a used DISABLED row lands on PAUSED (remaining kept)."""
    code = normalize(code)
    state = (state or "").strip().upper()
    if state not in ("NEW", "DISABLED"):
        return {"ok": False, "error": "bad_state"}
    db.begin_claim()
    try:
        row = _locked_row(db, "code=%s", (code,))
        if row is None:
            db.commit()
            return {"ok": False, "error": "unknown"}
        if state == "NEW":
            used = bool(row["bound_mac"]) or int(row["used_secs"] or 0) > 0
            if row["state"] == "DISABLED" and used:
                # Re-enable of a used row: PAUSED keeps the remaining time
                # for the bound device instead of wiping usage.
                new_state = "PAUSED"
            elif used:
                db.commit()
                return {"ok": False, "error": "used"}
            else:
                new_state = "NEW"
        else:
            new_state = "DISABLED"
        if row["state"] == "DISABLED" and state == "DISABLED":
            db.commit()
            return {"ok": True, "state": "DISABLED", "noop": True}
        db.execute("UPDATE vouchers SET state=%s WHERE code=%s",
                   (new_state, code))
        log_event(db, code, "", "", "", "ADMIN", "state-" + new_state.lower(),
                  None)
        db.commit()
        return {"ok": True, "state": new_state}
    except Exception:
        db.rollback()
        raise


def admin_release(db, code):
    """Clear bound_mac (non-ACTIVE only): next claim rebinds. The operator
    escape hatch for device changes; ACTIVE is refused (pause first)."""
    code = normalize(code)
    db.begin_claim()
    try:
        row = _locked_row(db, "code=%s", (code,))
        if row is None:
            db.commit()
            return {"ok": False, "error": "unknown"}
        if row["state"] == "ACTIVE":
            db.commit()
            return {"ok": False, "error": "active"}
        if not row["bound_mac"]:
            db.commit()
            return {"ok": True, "noop": True}
        db.execute("UPDATE vouchers SET bound_mac=NULL, last_ip=NULL,"
                   " last_token=NULL WHERE code=%s", (code,))
        log_event(db, code, "", "", "", "ADMIN", "release", None)
        db.commit()
        return {"ok": True}
    except Exception:
        db.rollback()
        raise


def admin_extend(db, code, add_secs):
    """Grow total_secs (cap 60d). EXPIRED flips to PAUSED so the bound
    device can resume; other states keep their state."""
    code = normalize(code)
    try:
        add_secs = int(add_secs)
    except (TypeError, ValueError):
        return {"ok": False, "error": "bad_secs"}
    if add_secs < 60 or add_secs > MAX_TOTAL_SECS:
        return {"ok": False, "error": "bad_secs"}
    db.begin_claim()
    try:
        row = _locked_row(db, "code=%s", (code,))
        if row is None:
            db.commit()
            return {"ok": False, "error": "unknown"}
        total = int(row["total_secs"] or 0) + add_secs
        if total > MAX_TOTAL_SECS:
            db.commit()
            return {"ok": False, "error": "cap"}
        new_state = "PAUSED" if row["state"] == "EXPIRED" else row["state"]
        db.execute("UPDATE vouchers SET total_secs=%s, state=%s"
                   " WHERE code=%s", (total, new_state, code))
        log_event(db, code, "", "", "", "ADMIN", "extend", total)
        db.commit()
        return {"ok": True, "total_secs": total, "state": new_state,
                "price_php": tier_price(total)}
    except Exception:
        db.rollback()
        raise


def admin_delete(db, code):
    """Remove NEW + never-bound rows only (unsold inventory). Audit event
    is written first so the deletion itself stays on record."""
    code = normalize(code)
    db.begin_claim()
    try:
        row = _locked_row(db, "code=%s", (code,))
        if row is None:
            db.commit()
            return {"ok": False, "error": "unknown"}
        if row["state"] != "NEW":
            db.commit()
            return {"ok": False, "error": "state"}
        if row["bound_mac"] or int(row["used_secs"] or 0) > 0:
            db.commit()
            return {"ok": False, "error": "used"}
        log_event(db, code, "", "", "", "ADMIN", "delete", None)
        db.execute("DELETE FROM vouchers WHERE code=%s", (code,))
        db.commit()
        return {"ok": True}
    except Exception:
        db.rollback()
        raise


def format_claim(result):
    if result["decision"] == "ALLOW":
        line = "ALLOW %d %d %d" % (result["remaining"], UP_KBPS, DOWN_KBPS)
        if result.get("evict"):
            line += " EVICT %s" % result["evict"]
        return line + "\n"
    return "DENY %s\n" % result.get("reason", "denied")


class Handler(BaseHTTPRequestHandler):
    psk = os.environ.get("VOUCHER_PSK", "")
    server_version = "VoucherAPI/2"

    def log_message(self, *a):
        pass

    def _psk_ok(self, given):
        return bool(self.psk) and hmac.compare_digest(str(given or ""),
                                                      self.psk)

    def _claim_body(self, fields):
        """Returns (http_code, body). Never raises: errors become generic DENY."""
        try:
            db = DB.connect()
        except BackendError as exc:
            log.error("backend unavailable: %s", exc)
            return 200, b"DENY backend_unavailable\n"
        try:
            result = claim_voucher(
                db, (fields.get("voucher") or [""])[0],
                (fields.get("mac") or [""])[0],
                (fields.get("ip") or [""])[0],
                (fields.get("token") or [""])[0])
            return 200, format_claim(result).encode()
        except Exception:
            log.error("claim failed:\n%s", traceback.format_exc())
            return 200, b"DENY error\n"
        finally:
            db.close()

    def _resume_body(self, fields):
        """POST /resume handler body. Codeless MAC-bound resume; never raises
        outward. Response lines match /claim shape (no voucher code)."""
        try:
            db = DB.connect()
        except BackendError as exc:
            log.error("backend unavailable: %s", exc)
            return 200, b"DENY backend_unavailable\n"
        try:
            result = resume_voucher(
                db, (fields.get("mac") or [""])[0],
                (fields.get("ip") or [""])[0],
                (fields.get("token") or [""])[0])
            return 200, format_claim(result).encode()
        except Exception:
            log.error("resume failed:\n%s", traceback.format_exc())
            return 200, b"DENY error\n"
        finally:
            db.close()

    def _pause_body(self, fields):
        """POST /pause handler body. Idempotent freeze; never raises outward."""
        try:
            db = DB.connect()
        except BackendError as exc:
            log.error("backend unavailable: %s", exc)
            return 200, b"DENY backend_unavailable\n"
        try:
            result = pause_voucher(
                db, (fields.get("mac") or [""])[0],
                (fields.get("code") or [""])[0],
                (fields.get("why") or [""])[0] or "deauth")
            if result["paused"]:
                body = "PAUSED %d\n" % result["remaining"]
            else:
                body = "NOOP\n"
            return 200, body.encode()
        except Exception:
            log.error("pause failed:\n%s", traceback.format_exc())
            return 200, b"DENY error\n"
        finally:
            db.close()

    def do_OPTIONS(self):
        # Preflight for browser SPAs (portal + admin API only). Unknown
        # paths get no CORS headers (fail closed, no origin echo).
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path.startswith(("/portal/", "/admin/api/")):
                extra = {"Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                         "Access-Control-Allow-Headers":
                         "Content-Type, X-PSK",
                         "Access-Control-Max-Age": "600"}
                extra.update(cors_headers(self))
                self.send_response(204)
                for key, value in extra.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self._send(404, "text/plain", b"DENY unknown\n")
        except Exception:
            log.error("OPTIONS failed:\n%s", traceback.format_exc())
            try:
                self._send(500, "text/plain", b"error\n")
            except Exception:
                pass

    def do_GET(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/healthz":
                return self._send(200, "text/plain", b"ok\n")
            if parsed.path == "/admin":
                return self._serve_admin_page()
            if parsed.path in ("/admin/api/stats", "/admin/api/vouchers",
                               "/admin/api/events"):
                qs = urllib.parse.parse_qs(parsed.query)
                if not admin_ok(qs.get("psk", [""])[0] or
                                self.headers.get("X-PSK", "")):
                    return self._send_json(403, {"error": "auth"})
                try:
                    db = DB.connect()
                except BackendError as exc:
                    log.error("backend unavailable: %s", exc)
                    return self._send_json(503, {"error": "backend"})
                try:
                    if parsed.path == "/admin/api/stats":
                        body = admin_stats(db)
                    elif parsed.path == "/admin/api/vouchers":
                        body = admin_list(
                            db, qs.get("state", [""])[0],
                            qs.get("q", [""])[0],
                            qs.get("limit", ["50"])[0],
                            qs.get("offset", ["0"])[0])
                    else:
                        body = admin_events(
                            db, qs.get("limit", ["50"])[0])
                except Exception:
                    log.error("admin GET failed:\n%s",
                              traceback.format_exc())
                    return self._send_json(500, {"error": "error"})
                finally:
                    db.close()
                return self._send_json(200, body)
            if parsed.path == "/portal/rates":
                if portal_limited(self.client_address[0]):
                    return self._send_json(
                        429, {"ok": False, "error": "rate_limited"})
                return self._send_json(200, portal_rates())
            if parsed.path == "/session":
                qs = urllib.parse.parse_qs(parsed.query)
                if not self._psk_ok(qs.get("psk", [""])[0] or
                                    self.headers.get("X-PSK", "")):
                    return self._send(403, "text/plain", b"DENY auth\n")
                try:
                    db = DB.connect()
                except BackendError as exc:
                    log.error("backend unavailable: %s", exc)
                    return self._send(503, "text/plain", b"error\n")
                try:
                    if qs.get("mac", [""])[0]:
                        body = json.dumps(session_info_by_mac(
                            db, qs.get("mac", [""])[0])).encode()
                    else:
                        body = json.dumps(session_info(
                            db, qs.get("code", [""])[0])).encode()
                except Exception:
                    log.error("session failed:\n%s", traceback.format_exc())
                    return self._send(500, "text/plain", b"error\n")
                finally:
                    db.close()
                return self._send(200, "application/json", body)
            return self._send(404, "text/plain", b"DENY unknown\n")
        except Exception:
            log.error("GET failed:\n%s", traceback.format_exc())
            return self._send(500, "text/plain", b"error\n")

    def _read_body(self, max_bytes=65536):
        """Read a POST body with either Content-Length or chunked framing.

        The EAP's uclient-fetch sends --post-data chunked with NO
        Content-Length; without this helper its body reads as empty and every
        claim fails closed with DENY auth. Malformed framing returns b"" and
        the caller fails closed through the normal path. Bounded reads only.
        """
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            return None
        if length:
            if length > max_bytes:
                return None
            return self.rfile.read(length)
        if "chunked" not in (self.headers.get("Transfer-Encoding", "") or "").lower():
            return b""
        chunks = []
        total = 0
        rfile = self.rfile
        while True:
            line = rfile.readline(128).decode("ascii", "replace").strip()
            if not line:
                return None
            try:
                size = int(line.split(";", 1)[0].strip(), 16)
            except ValueError:
                return None
            if size == 0:
                rfile.readline(16)
                break
            if size < 0 or total + size > max_bytes:
                return None
            buf = b""
            while len(buf) < size:
                part = rfile.read(size - len(buf))
                if not part:
                    return None
                buf += part
            chunks.append(buf)
            total += size
            rfile.readline(16)
        return b"".join(chunks)

    def do_POST(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path not in ("/claim", "/pause", "/session", "/resume",
                                   "/admin/api/create",
                                   "/admin/api/set_state",
                                   "/admin/api/release",
                                   "/admin/api/extend",
                                   "/admin/api/delete",
                                   "/portal/status", "/portal/pause",
                                   "/portal/resume"):
                return self._send(404, "text/plain", b"DENY unknown\n")
            raw = self._read_body()
            if raw is None:
                return self._send(400, "text/plain", b"DENY malformed\n")
            fields = urllib.parse.parse_qs(
                raw.decode("utf-8", "replace"))
            if parsed.path in ("/portal/status", "/portal/pause",
                               "/portal/resume"):
                # Public customer surface: code-in-body (never URLs/logs),
                # rate-limited, no PSK by design (code IS the credential).
                if portal_code_limited(self.client_address[0]):
                    return self._send_json(
                        429, {"ok": False, "error": "rate_limited"})
                code = (fields.get("code") or [""])[0]
                try:
                    db = DB.connect()
                except BackendError as exc:
                    log.error("backend unavailable: %s", exc)
                    return self._send_json(503, {"ok": False,
                                                 "error": "backend"})
                try:
                    if parsed.path == "/portal/status":
                        body = portal_status(db, code)
                    elif parsed.path == "/portal/pause":
                        result = pause_voucher(db, code=code)
                        body = {"ok": True, "paused": result["paused"],
                                "remaining_seconds": result["remaining"]}
                    else:
                        body = resume_by_code(db, code)
                except Exception:
                    log.error("portal POST failed:\n%s",
                              traceback.format_exc())
                    return self._send_json(500, {"ok": False,
                                                 "error": "error"})
                finally:
                    db.close()
                return self._send_json(200, body)
            if parsed.path.startswith("/admin/api/"):
                if not admin_ok((fields.get("psk") or [""])[0] or
                                self.headers.get("X-PSK", "")):
                    return self._send_json(403, {"error": "auth"})
                try:
                    db = DB.connect()
                except BackendError as exc:
                    log.error("backend unavailable: %s", exc)
                    return self._send_json(503, {"error": "backend"})
                try:
                    if parsed.path == "/admin/api/create":
                        body = admin_create(
                            db, (fields.get("code") or [""])[0],
                            (fields.get("total_secs") or [""])[0])
                    elif parsed.path == "/admin/api/set_state":
                        body = admin_set_state(
                            db, (fields.get("code") or [""])[0],
                            (fields.get("state") or [""])[0])
                    elif parsed.path == "/admin/api/release":
                        body = admin_release(
                            db, (fields.get("code") or [""])[0])
                    elif parsed.path == "/admin/api/extend":
                        body = admin_extend(
                            db, (fields.get("code") or [""])[0],
                            (fields.get("add_secs") or [""])[0])
                    else:
                        body = admin_delete(
                            db, (fields.get("code") or [""])[0])
                except Exception:
                    log.error("admin POST failed:\n%s",
                              traceback.format_exc())
                    return self._send_json(500, {"error": "error"})
                finally:
                    db.close()
                return self._send_json(200, body)
            if not self._psk_ok((fields.get("psk") or [""])[0]):
                return self._send(403, "text/plain", b"DENY auth\n")
            if parsed.path == "/pause":
                code, body = self._pause_body(fields)
                return self._send(code, "text/plain", body)
            if parsed.path == "/resume":
                code, body = self._resume_body(fields)
                return self._send(code, "text/plain", body)
            if parsed.path == "/session":
                # POST variant keeps the PSK out of URLs (EAP uses this).
                if not fields.get("mac", [""])[0]:
                    return self._send(400, "text/plain", b"DENY malformed\n")
                try:
                    db = DB.connect()
                except BackendError as exc:
                    log.error("backend unavailable: %s", exc)
                    return self._send(503, "text/plain", b"error\n")
                try:
                    body = json.dumps(session_info_by_mac(
                        db, fields.get("mac", [""])[0])).encode()
                except Exception:
                    log.error("session failed:\n%s",
                              traceback.format_exc())
                    return self._send(500, "text/plain", b"error\n")
                finally:
                    db.close()
                return self._send(200, "application/json", body)
            code, body = self._claim_body(fields)
            return self._send(code, "text/plain", body)
        except Exception:
            log.error("POST failed:\n%s", traceback.format_exc())
            return self._send(500, "text/plain", b"error\n")

    def _send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, code, obj, extra=None):
        try:
            body = json.dumps(obj).encode()
        except Exception:
            body = b'{"error":"error"}'
            code = 500
        merged = dict(cors_headers(self))
        merged.update(extra or {})
        self._send(code, "application/json", body, merged)

    def _serve_admin_page(self):
        """Empty dashboard shell (no data, no key inside). All data calls
        are separately gated by admin_ok; a missing file is a plain 404."""
        try:
            here = os.path.dirname(os.path.abspath(__file__))
            with open(os.path.join(here, "admin.html"), "rb") as fh:
                return self._send(200, "text/html", fh.read())
        except OSError:
            return self._send(404, "text/plain", b"DENY unknown\n")


def check_backend():
    """Startup probe: returns backend kind or raises BackendError."""
    db = DB.connect()
    try:
        db.execute("SELECT 1")
        return db.kind
    finally:
        db.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    if not os.environ.get("VOUCHER_PSK"):
        raise SystemExit("VOUCHER_PSK is required (never empty in production)")
    if not os.environ.get("ADMIN_PSK"):
        log.warning("ADMIN_PSK unset: /admin/api/* will deny everything")
    try:
        kind = check_backend()
    except BackendError as exc:
        # Fail closed but stay up so /claim keeps answering generic DENY.
        log.error("startup backend check failed: %s", exc)
        kind = "unavailable"
    log.info("backend=%s host=%s port=%d (psk configured, values redacted)",
             kind, HOST, PORT)
    HTTPServer((HOST, PORT), Handler).serve_forever()
