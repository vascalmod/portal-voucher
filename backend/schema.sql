-- Stage 2 voucher schema (PostgreSQL = production).
-- DEPLOYMENT MODEL (explicit schema install — api.py never runs DDL):
--   The operator installs this file separately against the production database
--   (e.g. psql "$DATABASE_URL" -f backend/schema.sql) BEFORE starting the API,
--   and re-runs it on schema upgrades. backend/api.py opens the database and
--   validates/claims against existing tables; it creates no tables, runs no
--   migrations, and never mutates schema at startup, so an existing production
--   database is never altered by (re)starting the service.
--   backend/test_pg.py loads THIS file verbatim into scratch databases to prove
--   the contract the API is coded against.
-- One database, one validation function for BOTH Android CPD and Chrome.
-- Pause-ready columns (used_secs, resume_ts, PAUSED state) exist now but only
-- accrue in Stage 3. Stage 2 performs initial authorization only.
-- Timestamps are real TIMESTAMPTZ with UTC now() defaults (never app strings).

CREATE TABLE IF NOT EXISTS vouchers (
    code         TEXT PRIMARY KEY,          -- normalized: UPPER, A-Z0-9-, 4..20 chars
    total_secs   INTEGER NOT NULL DEFAULT 21600 CHECK (total_secs >= 0),  -- 6 hours plan
    used_secs    INTEGER NOT NULL DEFAULT 0 CHECK (used_secs >= 0),       -- Stage 3 accrues on deauth
    CONSTRAINT used_within_total CHECK (used_secs <= total_secs),
    state        TEXT NOT NULL DEFAULT 'NEW'
                     CHECK (state IN ('NEW','ACTIVE','PAUSED','EXPIRED','DISABLED')),
    bound_mac    TEXT,                      -- transient metadata, NEVER identity
    last_ip      TEXT,
    last_token   TEXT,
    first_seen   TIMESTAMPTZ,
    last_auth    TIMESTAMPTZ,
    resume_ts    TIMESTAMPTZ,               -- Stage 3 pause accounting anchor
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS events (
    id             BIGSERIAL PRIMARY KEY,
    code           TEXT NOT NULL,
    mac            TEXT,
    ip             TEXT,
    token          TEXT,
    decision       TEXT NOT NULL,           -- ALLOW / DENY
    reason         TEXT NOT NULL,           -- invalid/unknown/expired/disabled/paused/
                                           -- rebound/fresh/rerequest/backend_deny...
    remaining_secs INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_events_code ON events (code);
CREATE INDEX IF NOT EXISTS idx_events_created ON events (created_at);
CREATE INDEX IF NOT EXISTS idx_vouchers_bound ON vouchers (bound_mac);
