-- LOCAL TEST SEED ONLY. Never production data. No secrets in this repo.
-- PORTAL-TEST is deliberately ABSENT (retired): claiming it must DENY/unknown.
-- Production seeding is a separate manual step on the Ubuntu host.

INSERT INTO vouchers (code, total_secs, used_secs, state) VALUES
 ('TEST-6H',      21600,     0, 'NEW'),
 ('TEST-USED',    21600, 21600, 'ACTIVE'),
 ('TEST-DISABLED',21600,     0, 'DISABLED'),
 ('TEST-PAUSED',  21600,  3600, 'PAUSED')
ON CONFLICT (code) DO UPDATE SET
 total_secs=excluded.total_secs, used_secs=excluded.used_secs, state=excluded.state;
