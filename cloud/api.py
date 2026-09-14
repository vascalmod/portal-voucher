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

Backend selection (explicit; NEVER silent):
  DATABASE_URL set (postgres scheme) -> PostgreSQL ONLY via the `psycopg` v3
      driver (`pip install "psycopg[binary]"`). Driver missing, URL bad, or DB
      unreachable -> log a clear server-side error and answer every /claim
      with a generic DENY (fail closed). SQLite is never used in this mode.
  DATABASE_URL unset + VOUCHER_DB set -> SQLite explicit-dev backend
      (stand-in with equivalent semantics; never presented as PostgreSQL).
  Neither set -> refuse startup with a clear error.

Config env: DATABASE_URL, VOUCHER_DB, VOUCHER_PSK (required; compare_digest),
HOST (default 127.0.0.1; production HOST=0.0.0.0 or the Ubuntu LAN IP — the API
is an internal EAP-to-Ubuntu service, never Internet-facing),
PORT (default 8080), UP_KBPS / DOWN_KBPS (default 10240 = 10 Mbps; EAP
calibration step confirms the mapping).

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
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CODE_RE = re.compile(r"^[A-Z0-9-]{4,20}$")

UP_KBPS = int(os.environ.get("UP_KBPS", "10240"))
DOWN_KBPS = int(os.environ.get("DOWN_KBPS", "10240"))

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

    def do_GET(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/healthz":
                return self._send(200, "text/plain", b"ok\n")
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
            if parsed.path not in ("/claim", "/pause", "/session", "/resume"):
                return self._send(404, "text/plain", b"DENY unknown\n")
            raw = self._read_body()
            if raw is None:
                return self._send(400, "text/plain", b"DENY malformed\n")
            fields = urllib.parse.parse_qs(
                raw.decode("utf-8", "replace"))
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

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


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
    try:
        kind = check_backend()
    except BackendError as exc:
        # Fail closed but stay up so /claim keeps answering generic DENY.
        log.error("startup backend check failed: %s", exc)
        kind = "unavailable"
    log.info("backend=%s host=%s port=%d (psk configured, values redacted)",
             kind, HOST, PORT)
    HTTPServer((HOST, PORT), Handler).serve_forever()
