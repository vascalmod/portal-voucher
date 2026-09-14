#!/usr/bin/env python3
"""SQLite explicit-dev suite for backend/api.py (stdlib only, temp DB).

Covers the claim matrix on the dev backend. PostgreSQL coverage lives in
backend/test_pg.py (needs TEST_DATABASE_URL). No network.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import api


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self._old_db = os.environ.get("VOUCHER_DB")
        self._old_url = os.environ.get("DATABASE_URL")
        os.environ.pop("DATABASE_URL", None)
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        os.environ["VOUCHER_DB"] = self.tmp.name
        # NOTE: api reads VOUCHER_DB at connect time via module global, so
        # rebind it explicitly (import-time default would be stale/empty).
        api.VOUCHER_DB = self.tmp.name
        api.DATABASE_URL = ""
        self.db = api.DB.connect()
        self.assertEqual(self.db.kind, "sqlite")
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state) VALUES "
            "('TEST-6H',21600,0,'NEW'),('TEST-USED',21600,21600,'ACTIVE'),"
            "('TEST-DISABLED',21600,0,'DISABLED'),"
            "('TEST-PAUSED',21600,3600,'PAUSED')")
        self.db.commit()

    def tearDown(self):
        self.db.close()
        os.unlink(self.tmp.name)
        if self._old_db is None:
            os.environ.pop("VOUCHER_DB", None)
        else:
            os.environ["VOUCHER_DB"] = self._old_db
        if self._old_url is None:
            os.environ.pop("DATABASE_URL", None)
        else:
            os.environ["DATABASE_URL"] = self._old_url

    def test_fresh_allow_full_remaining(self):
        r = api.claim_voucher(self.db, "test-6h", "AA:BB:CC:DD:EE:01",
                              "10.0.0.200", "tok1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertEqual(r["remaining"], 21600)
        self.assertIsNone(r["evict"])
        self.assertIn("ALLOW 21600 10240 10240", api.format_claim(r))

    def test_unknown_deny(self):
        r = api.claim_voucher(self.db, "PORTAL-TEST", "AA:BB:CC:DD:EE:99",
                              "10.0.0.200", "t")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "unknown"))

    def test_bad_charset_deny(self):
        for bad in ["A;B", "A&B", "a b", "x" * 21, "ab", "vouch_er"]:
            r = api.claim_voucher(self.db, bad, "AA:BB:CC:DD:EE:01", "", "")
            self.assertEqual(r["decision"], "DENY", bad)

    def test_exhausted_expires(self):
        r = api.claim_voucher(self.db, "TEST-USED", "AA:BB:CC:DD:EE:02", "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "expired"))
        st = self.db.row("SELECT state FROM vouchers WHERE code=%s",
                         ("TEST-USED",))["state"]
        self.assertEqual(st, "EXPIRED")

    def test_disabled_deny(self):
        r = api.claim_voucher(self.db, "TEST-DISABLED", "AA:BB:CC:DD:EE:03",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "disabled"))

    def test_paused_resumes_on_claim(self):
        # Stage 3: PAUSED + remaining + valid claim -> ACTIVE (resume).
        r = api.claim_voucher(self.db, "TEST-PAUSED", "AA:BB:CC:DD:EE:04",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("ALLOW", "resumed"))
        self.assertEqual(r["remaining"], 18000)
        row = self.db.row("SELECT state, resume_ts FROM vouchers"
                          " WHERE code=%s", ("TEST-PAUSED",))
        self.assertEqual(row["state"], "ACTIVE")
        self.assertIsNotNone(row["resume_ts"])

    def test_rebind_denied_bound_never_moves(self):
        # Strict binding: once bound, another MAC presenting the code is
        # denied (never silently rebound). Bound MAC, state and balance stay.
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01",
                          "10.0.0.200", "t1")
        r = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:02",
                              "10.0.0.201", "t2")
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "bound"))
        self.assertIsNone(r["evict"])
        self.assertNotIn("EVICT", api.format_claim(r))
        row = self.db.row("SELECT bound_mac, state, used_secs FROM vouchers"
                          " WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["bound_mac"], "AA:BB:CC:DD:EE:01")
        self.assertEqual(row["state"], "ACTIVE")
        self.assertEqual(int(row["used_secs"]), 0)

    def test_same_mac_idempotent(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        r = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "t1")
        self.assertEqual(r["decision"], "ALLOW")
        self.assertIsNone(r["evict"])

    def test_session_info_six_questions(self):
        s = api.session_info(self.db, "TEST-6H")
        for key in ("exists", "active", "paused", "remaining_seconds",
                    "active_session", "meta"):
            self.assertIn(key, s)
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:01", "", "")
        s = api.session_info(self.db, "TEST-6H")
        self.assertTrue(s["exists"] and s["active"] and not s["paused"])
        self.assertEqual(s["remaining_seconds"], 21600)
        self.assertEqual(s["active_session"]["mac"], "AA:BB:CC:DD:EE:01")
        self.assertFalse(api.session_info(self.db, "NOPE")["exists"])

    def test_session_info_by_mac(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:05", "", "")
        s = api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:05")
        self.assertTrue(s["active"])
        self.assertEqual(s["remaining_seconds"], 21600)
        self.assertNotIn("code", s)
        self.assertFalse(api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:99")["active"])

    def test_pause_idempotent_noop(self):
        # Nothing active (PAUSED row) => silent no-op.
        r = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:04")
        self.assertFalse(r["paused"])
        self.assertEqual(r["reason"], "noop")
        self.assertEqual(r["remaining"], 0)
        # No new event row for the no-op.
        ev = self.db.row("SELECT COUNT(*) AS c FROM events"
                           " WHERE decision='PAUSED'")
        self.assertEqual(ev["c"], 0)

    def test_pause_freezes_active(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:06", "", "")
        r = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:06")
        self.assertTrue(r["paused"])
        self.assertEqual(r["reason"], "paused")
        self.assertEqual(r["remaining"], 21600)
        row = self.db.row("SELECT state, resume_ts, used_secs"
                           " FROM vouchers WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["state"], "PAUSED")
        self.assertIsNone(row["resume_ts"])
        self.assertEqual(int(row["used_secs"]), 0)
        # Re-pause is an idempotent no-op.
        r2 = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:06")
        self.assertFalse(r2["paused"])
        self.assertEqual(r2["reason"], "noop")

    def test_pause_caps_accrual(self):
        # Claim 6h, then wait 2s, then pause: used <= 2s, remaining >= 21598.
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:07", "", "")
        import time as _t
        _t.sleep(0.05)
        r = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:07",
                              now=api.time.time())
        self.assertGreaterEqual(r["remaining"], 21598)
        self.assertLessEqual(r["remaining"], 21600)
        ev = self.db.row("SELECT decision, reason, remaining_secs"
                           " FROM events ORDER BY id DESC LIMIT 1")
        self.assertEqual(ev["decision"], "PAUSED")
        self.assertEqual(ev["reason"], "paused-deauth")

    def test_pause_exhausts_to_expired(self):
        self.db.execute(
            "UPDATE vouchers SET used_secs=21600, state='ACTIVE',"
            " resume_ts=NULL WHERE code='TEST-PAUSED'")
        self.db.commit()
        r = api.pause_voucher(self.db, code="TEST-PAUSED")
        self.assertTrue(r["paused"])
        self.assertEqual(r["reason"], "expired")
        row = self.db.row("SELECT state FROM vouchers WHERE code=%s",
                           ("TEST-PAUSED",))
        self.assertEqual(row["state"], "EXPIRED")

    def test_pause_resumes_on_claim(self):
        # Stage 3: PAUSED + remaining + valid claim -> ACTIVE (resume).
        r = api.claim_voucher(self.db, "TEST-PAUSED", "AA:BB:CC:DD:EE:04",
                              "", "")
        self.assertEqual((r["decision"], r["reason"]), ("ALLOW", "resumed"))
        self.assertEqual(r["remaining"], 18000)
        row = self.db.row("SELECT state, resume_ts FROM vouchers"
                            " WHERE code=%s", ("TEST-PAUSED",))
        self.assertEqual(row["state"], "ACTIVE")
        self.assertIsNotNone(row["resume_ts"])

    def test_pause_resume_lifecycle_keeps_remaining_gap_free(self):
        # 2h voucher: 1h used, then disconnect/pause, then reconnect later:
        # disconnected window must not count and the remaining hour must resume.
        self.db.execute(
            "UPDATE vouchers SET total_secs=7200, used_secs=0, state='NEW',"
            " bound_mac=NULL, last_ip=NULL, last_token=NULL, resume_ts=NULL"
            " WHERE code='TEST-6H'")
        self.db.commit()

        start = 1000.0
        pause_time = start + 3600.0
        resume_time = pause_time + 7200.0  # 2h later; gap must be ignored

        r1 = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:09",
                               "10.0.0.200", "tok-a", now=start)
        self.assertEqual(r1["decision"], "ALLOW")
        self.assertEqual(r1["remaining"], 7200)

        r2 = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:09", now=pause_time)
        self.assertTrue(r2["paused"])
        self.assertEqual(r2["remaining"], 3600)

        r3 = api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:09",
                               "10.0.0.200", "tok-b", now=resume_time)
        self.assertEqual((r3["decision"], r3["reason"]), ("ALLOW", "resumed"))
        self.assertEqual(r3["remaining"], 3600)
        row = self.db.row("SELECT state, used_secs, resume_ts FROM vouchers"
                          " WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["state"], "ACTIVE")
        self.assertEqual(int(row["used_secs"]), 3600)
        self.assertIsNotNone(row["resume_ts"])

    def test_session_info_live_accrues_capped(self):
        # ACTIVE with resume_ts in the past: accrues but capped at prev.
        self.db.execute(
            "UPDATE vouchers SET state='ACTIVE', resume_ts=datetime('now','-7200 seconds')"
            " WHERE code='TEST-6H'")
        self.db.commit()
        s = api.session_info(self.db, "TEST-6H", now=api.time.time())
        # Accrued 2h but total is 6h, so remaining = 4h = 14400.
        self.assertEqual(s["remaining_seconds"], 14400)
        self.assertTrue(s["active"])

    def test_session_info_by_mac_expired_flag(self):
        # MAC whose latest voucher ran out -> expired:true (CPD shows a
        # terminal EXPIRED page, never a misleading fresh login). No code.
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state,bound_mac)"
            " VALUES ('EXP-1',600,600,'EXPIRED','AA:BB:CC:DD:EE:E1')")
        self.db.commit()
        s = api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:E1")
        self.assertFalse(s["paused"])
        self.assertFalse(s["active"])
        self.assertEqual(s["remaining_seconds"], 0)
        self.assertTrue(s["expired"])
        self.assertNotIn("code", s)

    def test_session_info_by_mac_no_flag_otherwise(self):
        # Unknown MAC, live voucher MAC, DISABLED-bound MAC: no expired flag.
        s = api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:99")
        self.assertFalse(s["expired"])
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:05", "", "")
        s = api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:05")
        self.assertFalse(s["expired"])
        self.assertTrue(s["active"])
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state,bound_mac)"
            " VALUES ('DIS-1',600,0,'DISABLED','AA:BB:CC:DD:EE:D1')")
        self.db.commit()
        s = api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:D1")
        self.assertFalse(s["expired"])
        self.assertFalse(s["active"])
    def test_session_info_mac_lookup_no_code_leak(self):
        api.claim_voucher(self.db, "TEST-6H", "AA:BB:CC:DD:EE:08", "", "")
        s = api.session_info_by_mac(self.db, "AA:BB:CC:DD:EE:08")
        self.assertTrue(s["active"])
        self.assertIn("remaining_seconds", s)
        for k in ("code", "voucher", "total_secs"):
            self.assertNotIn(k, s)


class ResumeTests(unittest.TestCase):
    """POST /resume matrix: codeless MAC-bound resume, strict identity."""

    def setUp(self):
        self._old_db = os.environ.get("VOUCHER_DB")
        self._old_url = os.environ.get("DATABASE_URL")
        os.environ.pop("DATABASE_URL", None)
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        os.environ["VOUCHER_DB"] = self.tmp.name
        api.VOUCHER_DB = self.tmp.name
        api.DATABASE_URL = ""
        self.db = api.DB.connect()
        self.assertEqual(self.db.kind, "sqlite")
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state) VALUES "
            "('TEST-6H',21600,0,'NEW'),('TEST-USED',21600,21600,'ACTIVE'),"
            "('TEST-DISABLED',21600,0,'DISABLED'),"
            "('TEST-PAUSED',21600,3600,'PAUSED')")
        self.db.commit()

    def tearDown(self):
        self.db.close()
        os.unlink(self.tmp.name)
        if self._old_db is None:
            os.environ.pop("VOUCHER_DB", None)
        else:
            os.environ["VOUCHER_DB"] = self._old_db
        if self._old_url is None:
            os.environ.pop("DATABASE_URL", None)
        else:
            os.environ["DATABASE_URL"] = self._old_url

    def _bind_active(self, mac="AA:BB:CC:DD:EE:01", now=2000.0):
        r = api.claim_voucher(self.db, "TEST-6H", mac, "10.0.0.200", "tok",
                              now=now)
        self.assertEqual(r["decision"], "ALLOW")
        return r

    def test_first_claim_binds_mac(self):
        self._bind_active()
        row = self.db.row("SELECT bound_mac, state FROM vouchers"
                          " WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["bound_mac"], "AA:BB:CC:DD:EE:01")
        self.assertEqual(row["state"], "ACTIVE")

    def test_resume_same_mac_paused_to_active(self):
        self._bind_active(now=2000.0)
        p = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:01", now=2100.0)
        self.assertTrue(p["paused"])
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:01", "10.0.0.200",
                               "tok2", now=3000.0)
        self.assertEqual(r["decision"], "ALLOW")
        self.assertEqual(r["reason"], "resumed")
        self.assertEqual(r["remaining"], 21500)  # 100s consumed, gap ignored
        self.assertIn("ALLOW 21500 10240 10240", api.format_claim(r))
        row = self.db.row("SELECT state, used_secs, total_secs, resume_ts,"
                          " last_ip FROM vouchers WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["state"], "ACTIVE")
        self.assertEqual(int(row["used_secs"]), 100)
        self.assertEqual(int(row["total_secs"]), 21600)
        self.assertIsNotNone(row["resume_ts"])
        self.assertEqual(row["last_ip"], "10.0.0.200")

    def test_resume_case_insensitive_mac(self):
        self._bind_active(mac="aa:bb:cc:dd:ee:01", now=2000.0)
        api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:01", now=2100.0)
        r = api.resume_voucher(self.db, "Aa:Bb:Cc:Dd:Ee:01", "", "",
                               now=3000.0)
        self.assertEqual(r["decision"], "ALLOW")

    def test_resume_wrong_mac_denied(self):
        self._bind_active(now=2000.0)
        api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:01", now=2100.0)
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:99", "10.0.0.201",
                               "tokX", now=3000.0)
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "nomatch"))
        row = self.db.row("SELECT state, bound_mac FROM vouchers"
                          " WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["state"], "PAUSED")
        self.assertEqual(row["bound_mac"], "AA:BB:CC:DD:EE:01")

    def test_resume_new_voucher_denied(self):
        # NEW (never bound) has no MAC to resume: normal login required.
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:55", "", "",
                               now=3000.0)
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "nomatch"))

    def test_resume_bad_mac_denied(self):
        for bad in ("", "notamac", "AA:BB:CC:DD:EE:0", "AA-BB-CC-DD-EE-01"):
            r = api.resume_voucher(self.db, bad, "", "", now=3000.0)
            self.assertEqual(r["decision"], "DENY", bad)

    def test_resume_expired_denied(self):
        self.db.execute(
            "UPDATE vouchers SET total_secs=3600, used_secs=3600,"
            " state='PAUSED', bound_mac='AA:BB:CC:DD:EE:01', resume_ts=NULL"
            " WHERE code='TEST-6H'")
        self.db.commit()
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:01", "", "",
                               now=3000.0)
        self.assertEqual((r["decision"], r["reason"]), ("DENY", "expired"))
        row = self.db.row("SELECT state FROM vouchers WHERE code=%s",
                          ("TEST-6H",))
        self.assertEqual(row["state"], "EXPIRED")

    def test_resume_disabled_denied(self):
        self.db.execute(
            "UPDATE vouchers SET bound_mac='AA:BB:CC:DD:EE:02'"
            " WHERE code='TEST-DISABLED'")
        self.db.commit()
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:02", "", "",
                               now=3000.0)
        self.assertEqual(r["decision"], "DENY")

    def test_resume_active_reconnect_keeps_interval(self):
        # Lost OpenNDS session, backend still ACTIVE: re-auth must NOT reset
        # resume_ts, mint time, or double-charge.
        self._bind_active(now=2000.0)
        before = self.db.row("SELECT resume_ts, used_secs FROM vouchers"
                             " WHERE code=%s", ("TEST-6H",))
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:01", "10.0.0.200",
                               "tok2", now=2300.0)
        self.assertEqual((r["decision"], r["reason"]), ("ALLOW", "rerequest"))
        self.assertEqual(r["remaining"], 21300)
        after = self.db.row("SELECT resume_ts, used_secs, state FROM vouchers"
                            " WHERE code=%s", ("TEST-6H",))
        self.assertEqual(after["resume_ts"], before["resume_ts"])
        self.assertEqual(int(after["used_secs"]), 300)
        self.assertEqual(after["state"], "ACTIVE")

    def test_resume_concurrent_safe(self):
        # Two resumes at the same instant converge on one interval.
        self._bind_active(now=2000.0)
        api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:01", now=2100.0)
        r1 = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:01", "10.0.0.200",
                                "t1", now=3000.0)
        r2 = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:01", "10.0.0.200",
                                "t2", now=3000.0)
        self.assertEqual(r1["decision"], "ALLOW")
        self.assertEqual(r2["decision"], "ALLOW")
        self.assertEqual(r1["remaining"], r2["remaining"])
        row = self.db.row("SELECT state, used_secs FROM vouchers"
                          " WHERE code=%s", ("TEST-6H",))
        self.assertEqual(row["state"], "ACTIVE")
        self.assertEqual(int(row["used_secs"]), 100)

    def test_resume_result_carries_no_code(self):
        self._bind_active(now=2000.0)
        api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:01", now=2100.0)
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:01", "", "",
                               now=3000.0)
        for k in ("code", "voucher"):
            self.assertNotIn(k, r)
        body = api.format_claim(r)
        self.assertNotIn("TEST-6H", body)

    def test_full_lifecycle_gap_free_via_resume(self):
        # claim -> consume -> pause -> long gap -> resume: gap not consumed.
        self.db.execute(
            "UPDATE vouchers SET total_secs=7200, used_secs=0, state='NEW',"
            " bound_mac=NULL, resume_ts=NULL WHERE code='TEST-6H'")
        self.db.commit()
        self.assertEqual(api.claim_voucher(
            self.db, "TEST-6H", "AA:BB:CC:DD:EE:09", "10.0.0.200", "a",
            now=1000.0)["remaining"], 7200)
        p = api.pause_voucher(self.db, mac="AA:BB:CC:DD:EE:09", now=4600.0)
        self.assertEqual(p["remaining"], 3600)
        r = api.resume_voucher(self.db, "AA:BB:CC:DD:EE:09", "10.0.0.200",
                               "b", now=11800.0)
        self.assertEqual((r["decision"], r["reason"]), ("ALLOW", "resumed"))
        self.assertEqual(r["remaining"], 3600)
        row = self.db.row("SELECT used_secs FROM vouchers WHERE code=%s",
                          ("TEST-6H",))
        self.assertEqual(int(row["used_secs"]), 3600)


class BackendSelectionTests(unittest.TestCase):
    """DATABASE_URL configured => PostgreSQL attempted, SQLite never touched."""

    def test_pg_configured_never_falls_back_to_sqlite(self):
        canary = tempfile.NamedTemporaryFile(suffix=".db", delete=True)
        canary.close()  # path must NOT be created by a sqlite fallback
        api.DATABASE_URL = "postgresql://127.0.0.1:1/nodb"
        try:
            with self.assertRaises(api.BackendError):
                api.DB.connect()
        finally:
            api.DATABASE_URL = ""
        self.assertFalse(os.path.exists(canary.name),
                         "sqlite fallback created a file despite DATABASE_URL")

    def test_no_backend_configured_refuses(self):
        api.DATABASE_URL = ""
        api.VOUCHER_DB = ""
        try:
            with self.assertRaises(api.BackendError):
                api.DB.connect()
        finally:
            api.VOUCHER_DB = os.environ.get("VOUCHER_DB", "")


class PortalTests(unittest.TestCase):
    """Public customer surface: rates shape, status snapshots, code resume,
    and the sliding-window gates. No network."""

    def setUp(self):
        self._old_db = os.environ.get("VOUCHER_DB")
        self._old_url = os.environ.get("DATABASE_URL")
        os.environ.pop("DATABASE_URL", None)
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        os.environ["VOUCHER_DB"] = self.tmp.name
        api.VOUCHER_DB = self.tmp.name
        api.DATABASE_URL = ""
        self.db = api.DB.connect()
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state,"
            " bound_mac,resume_ts) VALUES "
            "('P-NEW',28800,0,'NEW',NULL,NULL),"
            "('P-ACT',28800,100,'ACTIVE','AA:BB:CC:DD:EE:01',"
            " datetime('now')),"
            "('P-PAUS',57600,3600,'PAUSED','AA:BB:CC:DD:EE:02',NULL),"
            "('P-EXP',100,100,'EXPIRED','AA:BB:CC:DD:EE:03',NULL),"
            "('P-DIS',28800,0,'DISABLED',NULL,NULL),"
            "('P-ZERO',100,100,'NEW',NULL,NULL)")
        self.db.commit()

    def tearDown(self):
        self.db.close()
        os.unlink(self.tmp.name)
        if self._old_db is None:
            os.environ.pop("VOUCHER_DB", None)
        else:
            os.environ["VOUCHER_DB"] = self._old_db
        if self._old_url is None:
            os.environ.pop("DATABASE_URL", None)
        else:
            os.environ["DATABASE_URL"] = self._old_url

    def test_rates_shape_matches_portal_card(self):
        r = api.portal_rates()
        self.assertEqual(len(r["tiers"]), 7)
        secs = [t["total_secs"] for t in r["tiers"]]
        self.assertEqual(secs, sorted(secs))
        by_secs = {t["total_secs"]: t for t in r["tiers"]}
        self.assertEqual(by_secs[28800]["price_php"], 5)
        self.assertEqual(by_secs[2592000]["price_php"], 500)
        self.assertEqual(by_secs[129600]["label"], "36 Hours (1.5 Days)")

    def test_status_snapshots(self):
        self.assertEqual(api.portal_status(self.db, "NOPE")["error"],
                         "not_valid")
        self.assertEqual(api.portal_status(self.db, "P-DIS")["error"],
                         "not_valid")
        self.assertEqual(api.portal_status(self.db, "bad!!")["error"],
                         "not_valid")
        new = api.portal_status(self.db, "P-NEW")
        self.assertEqual((new["ok"], new["active"], new["paused"],
                          new["remaining_seconds"]),
                         (True, False, False, 28800))
        act = api.portal_status(self.db, "P-ACT")
        self.assertTrue(act["ok"] and act["active"] and not act["paused"])
        self.assertGreater(act["remaining_seconds"], 0)
        pau = api.portal_status(self.db, "P-PAUS")
        self.assertTrue(pau["ok"] and pau["paused"])
        self.assertEqual(pau["remaining_seconds"], 57600 - 3600)
        exp = api.portal_status(self.db, "P-EXP")
        self.assertEqual((exp["ok"], exp["expired"],
                          exp["remaining_seconds"]),
                         (True, True, 0))

    def test_resume_by_code_matrix(self):
        self.assertEqual(api.resume_by_code(self.db, "NOPE")["error"],
                         "not_valid")
        self.assertEqual(api.resume_by_code(self.db, "P-DIS")["error"],
                         "not_valid")
        self.assertEqual(api.resume_by_code(self.db, "P-ZERO")["error"],
                         "expired")
        new = api.resume_by_code(self.db, "P-NEW")
        self.assertEqual((new["ok"], new["resumed"],
                          new["remaining_seconds"]),
                         (True, False, 28800))
        row = self.db.row("SELECT * FROM vouchers WHERE code=%s",
                          ("P-NEW",))
        self.assertEqual(row["state"], "NEW")  # untouched
        before = self.db.row("SELECT * FROM vouchers WHERE code=%s",
                             ("P-ACT",))["resume_ts"]
        act = api.resume_by_code(self.db, "P-ACT")
        self.assertEqual((act["ok"], act["resumed"]), (True, False))
        after = self.db.row("SELECT * FROM vouchers WHERE code=%s",
                            ("P-ACT",))["resume_ts"]
        self.assertEqual(str(before), str(after))  # anchor untouched
        pau = api.resume_by_code(self.db, "P-PAUS")
        self.assertEqual((pau["ok"], pau["resumed"],
                          pau["remaining_seconds"]),
                         (True, True, 57600 - 3600))
        row = self.db.row("SELECT * FROM vouchers WHERE code=%s",
                          ("P-PAUS",))
        self.assertEqual(row["state"], "ACTIVE")
        self.assertEqual(int(row["used_secs"]), 3600)  # preserved
        self.assertIsNotNone(row["resume_ts"])
        ev = self.db.row("SELECT * FROM events WHERE code=%s"
                         " ORDER BY id DESC", ("P-PAUS",))
        self.assertEqual((ev["decision"], ev["reason"]),
                         ("ALLOW", "resumed"))

    def test_rate_windows(self):
        ip1, ip2 = "10.9.9.101", "10.9.9.102"
        for _ in range(10):
            self.assertFalse(api.portal_code_limited(ip1))
        self.assertTrue(api.portal_code_limited(ip1))
        self.assertFalse(api.portal_code_limited(ip2))
        # ip2 already spent 1 of 30 "all" hits on the probe above.
        for _ in range(29):
            self.assertFalse(api.portal_limited(ip2))
        self.assertTrue(api.portal_limited(ip2))


if __name__ == "__main__":
    unittest.main(verbosity=2)
