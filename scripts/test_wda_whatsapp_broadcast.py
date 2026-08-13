#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""单测：E.164 归一化、深链构造、报告汇总 + Mock WDA HTTP 服务端端到端验证。"""
import json
import os
import sys
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import wda_whatsapp_broadcast as wb  # noqa: E402


class TestNormalizeE164(unittest.TestCase):
    def test_china_mobile(self):
        self.assertEqual(wb.normalize_e164("18078526388"), "8618078526388")
        self.assertEqual(wb.normalize_e164("17688540775"), "8617688540775")

    def test_already_international(self):
        self.assertEqual(wb.normalize_e164("+8618078526388"), "8618078526388")
        self.assertEqual(wb.normalize_e164("8618078526388"), "8618078526388")

    def test_double_zero(self):
        self.assertEqual(wb.normalize_e164("008618078526388"), "8618078526388")

    def test_leading_zero(self):
        self.assertEqual(wb.normalize_e164("018078526388"), "8618078526388")

    def test_empty_raises(self):
        with self.assertRaises(ValueError):
            wb.normalize_e164("")


class TestDeepLink(unittest.TestCase):
    def test_build_deep_link(self):
        b = wb.WhatsAppBroadcaster("http://localhost:8100")
        b.client.open_url = mock.Mock()
        b._open_chat_with_text("8618078526388", "某商品 100元 & 特价")
        called_url = b.client.open_url.call_args[0][0]
        self.assertEqual(b.client.open_url.call_args[1]["bundle_id"], wb.WHATSAPP_BUNDLE)
        parsed = urllib.parse.urlparse(called_url)
        self.assertEqual(parsed.scheme, "whatsapp")
        qs = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(qs["phone"], ["8618078526388"])
        self.assertEqual(qs["text"], ["某商品 100元 & 特价"])


class TestBroadcastReport(unittest.TestCase):
    def test_invalid_phone_does_not_crash(self):
        b = wb.WhatsAppBroadcaster("http://127.0.0.1:9")  # 不可达，但归一化先失败
        item = b.send_to_phone("", "hi")
        self.assertEqual(item["status"], "failed")
        self.assertIsNone(item["e164"])
        self.assertIn("手机号为空", item["error"])

    def test_report_structure(self):
        b = wb.WhatsAppBroadcaster("http://localhost:8100")
        fake = lambda phone, text: {  # noqa: E731
            "phone": phone, "e164": "8618078526388", "status": "sent",
            "durationMs": 10, "attempts": 1, "error": None, "steps": [],
        }
        with mock.patch.object(b, "send_to_phone", side_effect=fake):
            report = b.broadcast(["18078526388", "17688540775"], "你好")
        self.assertEqual(report["summary"]["total"], 2)
        self.assertEqual(report["summary"]["sent"], 2)
        self.assertEqual(report["summary"]["failed"], 0)
        self.assertEqual(len(report["items"]), 2)
        self.assertIn("meta", report)


class MockWDAHandler(BaseHTTPRequestHandler):
    STATE = None  # 由测试注入

    def log_message(self, *args):
        pass

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw) if raw else {}

    def do_GET(self):
        p = self.path
        if p == "/status":
            return self._send_json({"value": {"ready": True}})
        if p.endswith("/window/size"):
            return self._send_json({"value": {"width": 393, "height": 852}})
        if "/element/" in p and p.endswith("/text"):
            return self._send_json({"value": self.STATE["input_text"]})
        if "/element/" in p and p.endswith("/rect"):
            return self._send_json({"value": {"x": 0, "y": 700, "width": 300, "height": 44}})
        if p.endswith("/screenshot"):
            return self._send_json({"value": ""})
        if p == "/session/S1":
            return self._send_json({"value": {}})
        return self._send_json({"value": {}}, 404)

    def do_POST(self):
        p = self.path
        body = self._read_body()
        if p == "/session":
            return self._send_json({"value": {"sessionId": "S1", "capabilities": {}}})
        if p.endswith("/url"):
            url = body.get("url", "")
            self.STATE["deep_links"].append(url)
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            self.STATE["input_text"] = (qs.get("text") or [""])[0]
            return self._send_json({"value": {}})
        if p.endswith("/elements"):
            return self._send_json({"value": [{"ELEMENT": "E1"}]})
        if p.endswith("/element"):
            return self._send_json({"value": {"ELEMENT": "E2"}})
        if "/element/" in p and p.endswith("/click"):
            self.STATE["send_clicked"] = True
            self.STATE["input_text"] = ""
            return self._send_json({"value": {}})
        if "/element/" in p and p.endswith("/value"):
            self.STATE["input_text"] = (body.get("value") or [""])[0]
            return self._send_json({"value": {}})
        if p.endswith("/actions"):
            self.STATE["send_clicked"] = True
            self.STATE["input_text"] = ""
            return self._send_json({"value": {}})
        return self._send_json({"value": {}}, 404)


class TestFullHTTPChain(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), MockWDAHandler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.state = {"input_text": "", "deep_links": [], "send_clicked": False}
        MockWDAHandler.STATE = self.state

    def test_cli_entry_point(self):
        """完整入口：argparse + stdin payload + broadcast + stdout 报告 + 退出码。"""
        script = os.path.join(os.path.dirname(__file__), "wda_whatsapp_broadcast.py")
        import subprocess
        proc = subprocess.run(
            [sys.executable, script, "--wda", f"http://127.0.0.1:{self.port}",
             "--payload", "-"],
            input=json.dumps({"text": "你好", "phones": ["18078526388"]}),
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        report = json.loads(proc.stdout)
        self.assertEqual(report["summary"]["sent"], 1)
        self.assertEqual(report["summary"]["failed"], 0)
        self.assertEqual(report["items"][0]["e164"], "8618078526388")

    def test_check_preflight(self):
        b = wb.WhatsAppBroadcaster(f"http://127.0.0.1:{self.port}")
        result = b.check()
        self.assertTrue(result["wdaReachable"])
        self.assertTrue(result["wdaReady"])
        self.assertTrue(result["sessionCreated"])
        self.assertIsNone(result["error"])

    def test_broadcast_end_to_end(self):
        b = wb.WhatsAppBroadcaster(f"http://127.0.0.1:{self.port}")
        report = b.broadcast(["18078526388"], "你好")
        self.assertEqual(report["summary"]["total"], 1)
        self.assertEqual(report["summary"]["sent"], 1)
        self.assertEqual(report["summary"]["failed"], 0)
        self.assertTrue(self.state["send_clicked"])
        self.assertEqual(len(self.state["deep_links"]), 1)
        self.assertIn("whatsapp://send?", self.state["deep_links"][0])
        item = report["items"][0]
        self.assertEqual(item["status"], "sent")
        self.assertEqual(item["e164"], "8618078526388")
        self.assertGreaterEqual(item["durationMs"], 0)
        step_names = [s["step"] for s in item["steps"]]
        for expected in ["ensure_session", "open_chat", "input_ready", "text_verified", "send_tapped", "sent_verified"]:
            self.assertIn(expected, step_names)


if __name__ == "__main__":
    unittest.main(verbosity=2)
