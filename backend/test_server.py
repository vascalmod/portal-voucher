#!/usr/bin/env python3
"""HTTP-level tests for backend/api.py: LAN bind + auth + no-leak behavior.

Starts a real server subprocess (sqlite explicit-dev backend, temp DB) and
talks HTTP to it via 127.0.0.1 AND the machine LAN address with HOST=0.0.0.0,
proving the EAP225 -> Ubuntu-LAN-IP:PORT path shape. No PostgreSQL needed.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
import urllib.request
import urllib.error

API = os.path.join(os.path.dirname(__file__), "..", "backend", "api.py")
PSK = "server-test-psk"


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.0.0.1", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        cls.db.close()
        cls.port = free_port()
        env = dict(os.environ, VOUCHER_DB=cls.db.name, VOUCHER_PSK=PSK,
                   HOST="0.0.0.0", PORT=str(cls.port))
        cls.proc = subprocess.Popen(
            [sys.executable, API], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                urllib.request.urlopen(
                    "http://127.0.0.1:%d/healthz" % cls.port, timeout=2)
                break
            except OSError:
                time.sleep(0.2)
        else:
            cls.proc.terminate()
            raise RuntimeError("test server did not start")
        # seed one voucher through direct sqlite (dev-backend convenience)
        import sqlite3
        conn = sqlite3.connect(cls.db.name)
        conn.execute("INSERT INTO vouchers (code,total_secs,used_secs,state)"
                     " VALUES ('SRV-6H',21600,0,'NEW'),"
                     " ('SRV-CHUNK',21600,0,'NEW'),"
                     " ('SRV-RESUME',21600,0,'NEW')")
        conn.commit()
        conn.close()

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait()
        os.unlink(cls.db.name)

    def post(self, base, fields):
        data = urllib.parse.urlencode(fields).encode()
        try:
            resp = urllib.request.urlopen(base + "/claim", data, timeout=10)
            return resp.status, resp.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def post_pause(self, base, fields):
        data = urllib.parse.urlencode(fields).encode()
        try:
            resp = urllib.request.urlopen(base + "/pause", data, timeout=10)
            return resp.status, resp.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def post_resume(self, base, fields):
        data = urllib.parse.urlencode(fields).encode()
        try:
            resp = urllib.request.urlopen(base + "/resume", data, timeout=10)
            return resp.status, resp.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def post_session_mac(self, base, mac):
        data = urllib.parse.urlencode({"mac": mac}).encode()
        try:
            resp = urllib.request.urlopen(base + "/session", data, timeout=10)
            return resp.status, json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def test_claim_same_result_loopback_and_lan(self):
        lan = lan_ip()
        bodies = set()
        for base in ("http://127.0.0.1:%d" % self.port,
                     "http://%s:%d" % (lan, self.port)):
            code, body = self.post(base, {"voucher": "SRV-6H",
                                          "mac": "AA:BB:CC:DD:EE:01",
                                          "ip": "10.0.0.200", "token": "tok1",
                                          "psk": PSK})
            self.assertEqual(code, 200, base)
            self.assertTrue(body.startswith("ALLOW 21600 10240 10240"), body)
            bodies.add(body)
        # second device presenting the same code is DENIED (strict binding:
        # bound vouchers never move; the bound device resumes via /resume)
        code, body = self.post("http://%s:%d" % (lan, self.port),
                               {"voucher": "SRV-6H",
                                "mac": "AA:BB:CC:DD:EE:02",
                                "ip": "10.0.0.201", "token": "tok2",
                                "psk": PSK})
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("DENY bound"), body)
        self.assertNotIn("EVICT", body)

    def test_resume_codeless_same_mac(self):
        base = "http://127.0.0.1:%d" % self.port
        mac = "AA:BB:CC:DD:EE:B1"
        # bind SRV-RESUME to this MAC, then pause it
        code, body = self.post(base, {"voucher": "SRV-RESUME", "mac": mac,
                                      "ip": "10.0.0.220", "token": "tokR",
                                      "psk": PSK})
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("ALLOW "), body)
        code, body = self.post_pause(base, {"mac": mac, "psk": PSK})
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("PAUSED"), body)
        code, body = self.post_resume(base, {"mac": mac,
                                             "ip": "10.0.0.220",
                                             "token": "tok9", "psk": PSK})
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("ALLOW "), body)
        self.assertIn("10240 10240", body)
        self.assertNotIn("SRV-RESUME", body)
        # wrong MAC cannot resume; nothing leaks
        code, body = self.post_resume(base, {"mac": "AA:BB:CC:DD:EE:99",
                                             "psk": PSK})
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("DENY"), body)
        self.assertNotIn("SRV-RESUME", body)
        # PSK still gates /resume
        code, body = self.post_resume(base, {"mac": mac})
        self.assertEqual((code, body), (403, "DENY auth\n"))
        # /resume is POST-only
        try:
            urllib.request.urlopen(base + "/resume?mac=" + mac, timeout=10)
            self.fail("GET /resume answered")
        except urllib.error.HTTPError as exc:
            self.assertEqual(exc.code, 404)

    def test_auth_and_malformed(self):
        base = "http://127.0.0.1:%d" % self.port
        code, body = self.post(base, {"voucher": "SRV-6H", "psk": "wrong"})
        self.assertEqual((code, body), (403, "DENY auth\n"))
        code, body = self.post(base, {"voucher": "SRV-6H"})
        self.assertEqual((code, body), (403, "DENY auth\n"))
        code, body = self.post(base, {"voucher": "SRV-6H', ''); DROP",
                                      "psk": PSK})
        self.assertEqual(code, 200)
        self.assertTrue(body.startswith("DENY"), body)
        for _, b in [(code, body)]:
            for word in ("postgres", "psycopg", "Traceback", ".py", "/tmp/"):
                self.assertNotIn(word, b)

    def test_session_endpoint_psk_gated(self):
        base = "http://127.0.0.1:%d" % self.port
        req = urllib.request.Request(base + "/session?code=SRV-6H",
                                     headers={"X-PSK": PSK})
        info = json.loads(urllib.request.urlopen(req, timeout=10).read())
        for key in ("exists", "active", "paused", "remaining_seconds",
                    "active_session", "meta"):
            self.assertIn(key, info)
        try:
            urllib.request.urlopen(base + "/session?code=SRV-6H", timeout=10)
            self.fail("ungated session endpoint")
        except urllib.error.HTTPError as exc:
            self.assertEqual(exc.code, 403)


    def test_chunked_body_like_uclient_fetch(self):
        # Regression: EAP uclient-fetch POSTs chunked with NO Content-Length.
        import socket as _socket
        body = urllib.parse.urlencode(
            {"voucher": "SRV-CHUNK", "mac": "AA:BB:CC:DD:EE:0A",
             "ip": "10.0.0.210", "token": "chunk-01", "psk": PSK}).encode()
        chunks = "POST /claim HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked" \
            "\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n"
        chunks += "%X\r\n" % len(body) + body.decode() + "\r\n0\r\n\r\n"
        s = _socket.create_connection(("127.0.0.1", self.port), timeout=10)
        s.sendall(chunks.encode())
        resp = b""
        while True:
            part = s.recv(4096)
            if not part:
                break
            resp += part
        s.close()
        text = resp.decode("utf-8", "replace")
        self.assertIn("200", text.splitlines()[0])
        self.assertIn("ALLOW", text)

    def test_malformed_chunking_denied_safely(self):
        import socket as _socket
        for payload in ("POST /claim HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nZZZ\r\n",
                        "POST /claim HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"):
            s = _socket.create_connection(("127.0.0.1", self.port), timeout=10)
            s.sendall(payload.encode())
            try:
                s.shutdown(_socket.SHUT_WR)
            except OSError:
                pass
            resp = b""
            try:
                while True:
                    part = s.recv(4096)
                    if not part:
                        break
                    resp += part
            except (socket.timeout, ConnectionResetError):
                pass
            s.close()
            text = resp.decode("utf-8", "replace")
            self.assertTrue("DENY" in text or text == "", text)
            for word in ("Traceback", ".py", "/tmp/"):
                self.assertNotIn(word, text)


if __name__ == "__main__":
    print("LAN IP under test:", lan_ip())
    unittest.main(verbosity=2)
