-- Cloud DB import for Supabase SQL editor (paste whole file, Run).
-- Canonical source: backend/schema.sql (test_pg.py loads THAT file verbatim).
-- One-shot baseline: identical DDL + smoke-test voucher + least-privilege
-- anon grants for the direct-Supabase admin dashboard. Safe to re-run
-- (all CREATEs are IF NOT EXISTS; seed is ON CONFLICT DO NOTHING;
-- GRANTs are idempotent). No secrets in this file. Production vouchers
-- are created separately (voucher_admin.sh against the Supabase URL,
-- the admin dashboard, or more INSERTs below).
-- Worker/Railway/Python backend is unaffected (owner bypasses grants).

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

-- Least-privilege anon access for the direct-Supabase admin dashboard
-- (dashboard uses the anon key only; service_role never leaves Supabase).
-- Strips any over-broad defaults (TRUNCATE/TRIGGER/REFERENCES) first.
REVOKE ALL ON public.vouchers FROM anon;
REVOKE ALL ON public.events FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vouchers TO anon;
GRANT SELECT ON public.events TO anon;

-- Verify (expect: vouchers_visible >= 1, events_visible >= 0):
-- SELECT count(*) AS vouchers_visible FROM public.vouchers;
-- SELECT count(*) AS events_visible FROM public.events;
