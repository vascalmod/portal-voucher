#!/usr/bin/env python3
"""Admin-layer suite for backend/api.py (stdlib only, temp SQLite DB).

Covers tier pricing, the ADMIN_PSK gate, profit/inventory stats, and every
admin mutation's guard rails. No network. HTTP routing for /admin/api/*
is exercised separately against the live server matrix.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
import api


class AdminTests(unittest.TestCase):
    def setUp(self):
        self._old_db = os.environ.get("VOUCHER_DB")
        self._old_url = os.environ.get("DATABASE_URL")
        self._old_apsk = os.environ.get("ADMIN_PSK")
        os.environ.pop("DATABASE_URL", None)
        os.environ["ADMIN_PSK"] = "test-admin-key"
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        os.environ["VOUCHER_DB"] = self.tmp.name
        api.VOUCHER_DB = self.tmp.name
        api.DATABASE_URL = ""
        self.db = api.DB.connect()
        self.assertEqual(self.db.kind, "sqlite")
        # P5 sold, P10 sold-twice, P20 unsold, custom sold, custom unsold.
        self.db.execute(
            "INSERT INTO vouchers (code,total_secs,used_secs,state,"
            " bound_mac,last_ip) VALUES "
            "('SOLD-5',28800,0,'NEW','AA:BB:CC:DD:EE:01','10.0.0.2'),"
            "('SOLD-10A',57600,0,'PAUSED','AA:BB:CC:DD:EE:02','10.0.0.3'),"
            "('SOLD-10B',57600,100,'ACTIVE','AA:BB:CC:DD:EE:03','10.0.0.4'),"
            "('STOCK-20',129600,0,'NEW',NULL,NULL),"
            "('CUSTOM-S',9999,0,'NEW','AA:BB:CC:DD:EE:04','10.0.0.5'),"
            "('CUSTOM-U',9999,0,'NEW',NULL,NULL)")
        self.db.execute(
            "UPDATE vouchers SET resume_ts=datetime('now'),"
            " first_seen=datetime('now'), last_auth=datetime('now')"
            " WHERE bound_mac IS NOT NULL")
        self.db.commit()

    def tearDown(self):
        self.db.close()
        os.unlink(self.tmp.name)
        for k, v in (("VOUCHER_DB", self._old_db),
                     ("DATABASE_URL", self._old_url),
                     ("ADMIN_PSK", self._old_apsk)):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_tier_prices_match_portal_card(self):
        self.assertEqual(api.tier_price(28800), 5)
        self.assertEqual(api.tier_price(57600), 10)
        self.assertEqual(api.tier_price(129600), 20)
        self.assertEqual(api.tier_price(345600), 50)
        self.assertEqual(api.tier_price(777600), 100)
        self.assertEqual(api.tier_price(1641600), 200)
        self.assertEqual(api.tier_price(2592000), 500)
        self.assertIsNone(api.tier_price(9999))
        self.assertIsNone(api.tier_price("junk"))

    def test_admin_gate(self):
        self.assertTrue(api.admin_ok("test-admin-key"))
        self.assertFalse(api.admin_ok("wrong"))
        self.assertFalse(api.admin_ok(""))
        os.environ["ADMIN_PSK"] = ""
        self.assertFalse(api.admin_ok("test-admin-key"))
        os.environ["ADMIN_PSK"] = "test-admin-key"

    def test_stats_revenue_counts_sold_only(self):
        s = api.admin_stats(self.db)
        # Sold: P5 + 2xP10 + custom(unknown price). Revenue = 5+20 = 25.
        self.assertEqual(s["revenue_php"], 25)
        self.assertEqual(s["sold"], 4)
        self.assertEqual(s["unsold"], 2)
        tiers = {t["total_secs"]: t for t in s["by_tier"]}
        self.assertEqual(tiers[57600]["revenue_php"], 20)
        self.assertEqual(tiers[9999]["price_php"], None)
        self.assertEqual(tiers[129600]["unsold"], 1)
        self.assertEqual(s["by_state"]["NEW"], 4)
        self.assertEqual(s["active_now"], 1)
        self.assertGreater(s["liability_secs"], 0)

    def test_list_filter_search_pagination(self):
        all_rows = api.admin_list(self.db)
        self.assertEqual(all_rows["total"], 6)
        self.assertEqual(len(all_rows["rows"]), 6)
        new_only = api.admin_list(self.db, state="NEW")
        self.assertEqual(new_only["total"], 4)
        self.assertTrue(all(r["state"] == "NEW"
                            for r in new_only["rows"]))
        q = api.admin_list(self.db, q="sold-10")
        self.assertEqual(q["total"], 2)
        self.assertEqual(api.admin_list(self.db, state="BOGUS")["total"], 0)
        p1 = api.admin_list(self.db, limit=2, offset=0)
        p2 = api.admin_list(self.db, limit=2, offset=2)
        self.assertEqual(len(p1["rows"]), 2)
        self.assertNotEqual(p1["rows"][0]["code"], p2["rows"][0]["code"])
        row = [r for r in all_rows["rows"] if r["code"] == "SOLD-5"][0]
        self.assertEqual(row["price_php"], 5)
        self.assertGreaterEqual(row["remaining_secs"], 0)

    def test_create_guards(self):
        self.assertEqual(api.admin_create(self.db, "bad code!", 28800)
                         ["error"], "bad_code")
        self.assertEqual(api.admin_create(self.db, "OK-1", -5)["error"],
                         "bad_secs")
        self.assertEqual(api.admin_create(self.db, "OK-1", 0)["error"],
                         "bad_secs")
        self.assertEqual(api.admin_create(self.db, "SOLD-5", 28800)
                         ["error"], "exists")
        r = api.admin_create(self.db, "new-99", 57600)
        self.assertTrue(r["ok"])
        self.assertEqual(r["price_php"], 10)
        row = self.db.row("SELECT * FROM vouchers WHERE code=%s",
                          ("NEW-99",))
        self.assertEqual(row["state"], "NEW")
        ev = self.db.row("SELECT * FROM events WHERE code=%s"
                         " ORDER BY id DESC", ("NEW-99",))
        self.assertEqual((ev["decision"], ev["reason"]),
                         ("ADMIN", "create"))

    def test_set_state_guards(self):
        self.assertEqual(api.admin_set_state(self.db, "NOPE", "DISABLED")
                         ["error"], "unknown")
        self.assertEqual(api.admin_set_state(self.db, "STOCK-20", "ACTIVE")
                         ["error"], "bad_state")
        # Never-used row can park as NEW; used row cannot.
        self.assertTrue(api.admin_set_state(self.db, "STOCK-20",
                                            "DISABLED")["ok"])
        self.assertEqual(api.admin_set_state(self.db, "SOLD-5", "NEW")
                         ["error"], "used")
        # Re-enabling a used DISABLED row lands on PAUSED (time kept).
        self.db.execute("UPDATE vouchers SET state='DISABLED'"
                        " WHERE code='SOLD-5'")
        self.db.commit()
        r = api.admin_set_state(self.db, "SOLD-5", "NEW")
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "PAUSED")

    def test_release_guards(self):
        self.assertEqual(api.admin_release(self.db, "NOPE")["error"],
                         "unknown")
        self.assertEqual(api.admin_release(self.db, "SOLD-10B")["error"],
                         "active")
        r = api.admin_release(self.db, "STOCK-20")
        self.assertTrue(r["ok"] and r.get("noop"))
        self.assertTrue(api.admin_release(self.db, "SOLD-10A")["ok"])
        row = self.db.row("SELECT * FROM vouchers WHERE code=%s",
                          ("SOLD-10A",))
        self.assertIsNone(row["bound_mac"])
        self.assertEqual(row["state"], "PAUSED")

    def test_extend_guards(self):
        self.assertEqual(api.admin_extend(self.db, "NOPE", 3600)["error"],
                         "unknown")
        self.assertEqual(api.admin_extend(self.db, "STOCK-20", 30)["error"],
                         "bad_secs")
        self.assertEqual(api.admin_extend(self.db, "STOCK-20",
                                          99999999)["error"], "bad_secs")
        r = api.admin_extend(self.db, "STOCK-20", 3600)
        self.assertTrue(r["ok"])
        self.assertEqual(r["total_secs"], 129600 + 3600)
        self.assertEqual(r["state"], "NEW")
        # EXPIRED flips to PAUSED so the bound device can resume.
        self.db.execute("UPDATE vouchers SET state='EXPIRED',"
                        " bound_mac='AA:BB:CC:DD:EE:09',"
                        " used_secs=total_secs WHERE code='STOCK-20'")
        self.db.commit()
        r = api.admin_extend(self.db, "STOCK-20", 3600)
        self.assertTrue(r["ok"])
        self.assertEqual(r["state"], "PAUSED")

    def test_delete_guards(self):
        self.assertEqual(api.admin_delete(self.db, "NOPE")["error"],
                         "unknown")
        self.assertEqual(api.admin_delete(self.db, "SOLD-5")["error"],
                         "used")
        self.db.execute("UPDATE vouchers SET state='DISABLED'"
                        " WHERE code='CUSTOM-U'")
        self.db.commit()
        self.assertEqual(api.admin_delete(self.db, "CUSTOM-U")["error"],
                         "state")
        self.assertTrue(api.admin_delete(self.db, "STOCK-20")["ok"])
        self.assertIsNone(self.db.row("SELECT * FROM vouchers"
                                      " WHERE code=%s", ("STOCK-20",)))
        # Deletion itself stays on record.
        ev = self.db.row("SELECT * FROM events WHERE code=%s"
                         " ORDER BY id DESC", ("STOCK-20",))
        self.assertEqual((ev["decision"], ev["reason"]),
                         ("ADMIN", "delete"))

    def test_events_feed(self):
        api.admin_create(self.db, "feed-1", 28800)
        rows = api.admin_events(self.db, limit=5)["rows"]
        self.assertGreaterEqual(len(rows), 1)
        self.assertEqual(rows[0]["code"], "FEED-1")
        ids = [r["id"] for r in rows]
        self.assertEqual(ids, sorted(ids, reverse=True))


if __name__ == "__main__":
    unittest.main()
