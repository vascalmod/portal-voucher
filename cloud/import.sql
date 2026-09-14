-- Cloud DB import for Supabase SQL editor (paste whole file, Run).
-- Canonical source: backend/schema.sql (test_pg.py loads THAT file verbatim).
-- This copy is identical DDL + one live test voucher. Safe to re-run
-- (all CREATEs are IF NOT EXISTS; the seed is ON CONFLICT DO NOTHING).
-- No secrets in this file. Production vouchers are created separately
-- (voucher_admin.sh against the Supabase URL, or more INSERTs below).

CREATE TABLE IF NOT EXISTS vouchers (
    code         TEXT PRIMARY KEY,
    total_secs   INTEGER NOT NULL DEFAULT 21600 CHECK (total_secs >= 0),
    used_secs    INTEGER NOT NULL DEFAULT 0 CHECK (used_secs >= 0),
    CONSTRAINT used_within_total CHECK (used_secs <= total_secs),
    state        TEXT NOT NULL DEFAULT 'NEW'
                     CHECK (state IN ('NEW','ACTIVE','PAUSED','EXPIRED','DISABLED')),
    bound_mac    TEXT,
    last_ip      TEXT,
    last_token   TEXT,
    first_seen   TIMESTAMPTZ,
    last_auth    TIMESTAMPTZ,
    resume_ts    TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS events (
    id             BIGSERIAL PRIMARY KEY,
    code           TEXT NOT NULL,
    mac            TEXT,
    ip             TEXT,
    token          TEXT,
    decision       TEXT NOT NULL,
    reason         TEXT NOT NULL,
    remaining_secs INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_events_code ON events (code);
CREATE INDEX IF NOT EXISTS idx_events_created ON events (created_at);
CREATE INDEX IF NOT EXISTS idx_vouchers_bound ON vouchers (bound_mac);

-- Live smoke-test voucher (1h, fresh). Claim from Android, then Pause/Resume.
INSERT INTO vouchers (code, total_secs, used_secs, state) VALUES
 ('RAIL-TEST', 3600, 0, 'NEW')
ON CONFLICT (code) DO NOTHING;
