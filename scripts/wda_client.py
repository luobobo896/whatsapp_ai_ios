#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用 WDA（WebDriverAgent）HTTP 客户端，供微信/WhatsApp 自动化脚本复用。

只封装 W3C WebDriver + WDA 私有端点的基础操作，不含任何具体 App 的业务流程。
"""

import base64
import io
import json
import sys
import time
import urllib.error
import urllib.request


def predicate_literal(value):
    """把用户输入安全地放进 NSPredicate 字符串字面量。

    WDA 用 NSPredicate predicateWithFormat: 解析谓词，字符串既不能破坏引号，
    也不能含未转义的 %（会被当作格式化占位符）。
    """
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    return '"' + escaped + '"'


class WDAError(Exception):
    """WDA 返回错误，或 HTTP 层失败。"""

    def __init__(self, message, *, session_invalid=False):
        super().__init__(message)
        # True 表示会话/App 已失效，需要重建会话后重试
        self.session_invalid = session_invalid


class WDAClient:
    def __init__(self, base_url, timeout=15, verbose=False):
        self.base = base_url.rstrip("/")
        self.timeout = timeout
        self.verbose = verbose
        self.session_id = None
        self.scale = None  # 截图像素 / 逻辑点
        self._send_key_pt = None  # 缓存的发送键坐标（逻辑点）
        self._win_size = None  # 缓存的逻辑窗口尺寸 (width, height)

    # ---------- 基础 HTTP ----------
    def _request(self, method, path, body=None):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as e:
            raw = e.read()
            status = e.code
        except Exception as e:  # 连接失败/超时
            raise WDAError(f"HTTP {method} {path} 失败: {e}") from e
        if self.verbose:
            print(f"  [{method} {path}] {time.time()-t0:.1f}s -> {status}", file=sys.stderr)
        try:
            return status, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return status, {}

    def _raise_if_error(self, status, payload):
        if isinstance(payload, dict) and payload.get("value") and isinstance(payload["value"], dict):
            err = payload["value"].get("error")
            if err:
                msg = payload["value"].get("message", err)
                bad = any(k in msg for k in (
                    "not running", "No such session", "Invalid session",
                    "Application is not running", "session is not", "killed",
                    "crash", "crashed", "terminated", "stale"))
                raise WDAError(f"WDA {err}: {msg}", session_invalid=bad)
        if status >= 400:
            raise WDAError(f"HTTP {status}: {payload}")

    # ---------- 会话管理 ----------
    def create_session(self, bundle_id, delete_existing=True):
        """创建会话并拉起 App；有旧会话先删（避免并发会话）。"""
        if self.session_id and delete_existing:
            try:
                self._request("DELETE", f"/session/{self.session_id}")
            except Exception:
                pass
            self.session_id = None
        status, payload = self._request("POST", "/session", {
            "capabilities": {"alwaysMatch": {
                "bundleId": bundle_id, "shouldWaitForQuiescence": False}}})
        self._raise_if_error(status, payload)
        sid = (payload.get("value") or {}).get("sessionId") or payload.get("sessionId")
        if not sid:
            raise WDAError("创建会话失败: 无 sessionId")
        self.session_id = sid
        return sid

    def _session_path(self, path=""):
        return f"/session/{self.session_id}{path}"

    def alive(self):
        """会话是否仍可用（快速探测：查根 Application 元素）。"""
        if not self.session_id:
            return False
        try:
            status, payload = self._request("GET", self._session_path())
            return status == 200
        except WDAError:
            return False

    # ---------- 打开深链 / URL ----------
    def open_url(self, url, bundle_id=None, idle_timeout_ms=3000):
        """用 WDA /url 打开深链，可指定目标 App；深链可预填文本。"""
        body = {"url": url, "idleTimeoutMs": idle_timeout_ms}
        if bundle_id:
            body["bundleId"] = bundle_id
        status, payload = self._request("POST", self._session_path("/url"), body)
        self._raise_if_error(status, payload)

    # ---------- 元素操作 ----------
    def find(self, predicate, typ=None):
        """谓词查元素，返回 ELEMENT id 或 None。"""
        p = predicate
        if typ:
            p = f"type == '{typ}' AND {p}"
        status, payload = self._request("POST", self._session_path("/element"),
                                        {"using": "predicate string", "value": p})
        if status >= 400:
            # 找不到元素 WDA 返回 404 no such element
            if status == 404:
                return None
            self._raise_if_error(status, payload)
        v = payload.get("value")
        if isinstance(v, dict):
            return v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf")
        return None

    def find_all(self, predicate, typ=None):
        """谓词查多个元素，返回 ELEMENT id 列表（找不到返回空列表）。"""
        p = predicate
        if typ:
            p = f"type == '{typ}' AND {p}"
        status, payload = self._request("POST", self._session_path("/elements"),
                                        {"using": "predicate string", "value": p})
        if status == 404:
            return []
        if status >= 400:
            self._raise_if_error(status, payload)
        v = payload.get("value")
        if not isinstance(v, list):
            return []
        out = []
        for item in v:
            if isinstance(item, dict):
                eid = item.get("ELEMENT") or item.get("element-6066-11e4-a52e-4f735466cecf")
                if eid:
                    out.append(eid)
        return out

    def _logical_window_size(self):
        """返回逻辑窗口 (width, height)；失败返回 (None, None)，并缓存。"""
        if self._win_size is None:
            status, payload = self._request("GET", self._session_path("/window/size"))
            self._raise_if_error(status, payload)
            v = payload.get("value") or {}
            w = v.get("width")
            h = v.get("height")
            if isinstance(w, (int, float)) and isinstance(h, (int, float)) and w > 0:
                self._win_size = (float(w), float(h))
            else:
                self._win_size = (None, None)
        return self._win_size

    def click_element(self, eid):
        status, payload = self._request("POST", self._session_path(f"/element/{eid}/click"), {})
        self._raise_if_error(status, payload)

    def element_text(self, eid):
        status, payload = self._request("GET", self._session_path(f"/element/{eid}/text"))
        if status == 404:
            return None
        self._raise_if_error(status, payload)
        v = payload.get("value")
        return v if isinstance(v, str) else None

    def element_frame(self, eid):
        """返回 (x, y, w, h) 逻辑点；取不到返回 None。"""
        status, payload = self._request("GET", self._session_path(f"/element/{eid}/rect"))
        if status == 404:
            return None
        self._raise_if_error(status, payload)
        r = payload.get("value") or {}
        try:
            return (float(r["x"]), float(r["y"]), float(r["width"]), float(r["height"]))
        except (KeyError, TypeError):
            return None

    def set_value(self, eid, text):
        status, payload = self._request("POST", self._session_path(f"/element/{eid}/value"),
                                        {"value": [text]})
        self._raise_if_error(status, payload)

    def tap(self, x, y):
        """W3C pointer 点击。"""
        status, payload = self._request("POST", self._session_path("/actions"), {
            "actions": [{"type": "pointer", "id": "finger1",
                         "parameters": {"pointerType": "touch"},
                         "actions": [
                             {"type": "pointerMove", "duration": 0, "x": int(x), "y": int(y)},
                             {"type": "pointerDown", "button": 0},
                             {"type": "pause", "duration": 120},
                             {"type": "pointerUp", "button": 0}]}]})
        self._raise_if_error(status, payload)

    def screenshot_bytes(self):
        status, payload = self._request("GET", self._session_path("/screenshot"))
        self._raise_if_error(status, payload)
        return base64.b64decode(payload.get("value") or "")

    # ---------- 发送键定位（像素聚类） ----------
    def locate_send_key(self):
        """定位键盘/输入区右侧的发送键中心（逻辑点）。优先缓存。"""
        if self._send_key_pt:
            return self._send_key_pt
        try:
            from PIL import Image
        except ImportError:
            print("警告: 未安装 Pillow，发送键退回元素点击（可能点不准）", file=sys.stderr)
            return None
        png = self.screenshot_bytes()
        im = Image.open(io.BytesIO(png)).convert("RGB")
        w, h = im.size
        if not self.scale:
            lw, _ = self._logical_window_size()
            self.scale = (w / lw) if lw else (w / 393.0)  # 逻辑宽未知时兜底 393pt
        px = im.load()

        def is_send(r, g, b):
            green = g > 120 and g > r + 40 and g > b + 40
            orange = r > 190 and 90 < g < 200 and b < 130 and r > g + 30
            return green or orange

        # 底部 32%、右侧 55% 区域
        x0, y0 = int(w * 0.45), int(h * 0.68)
        cells = {}
        for y in range(y0, h, 2):
            for x in range(x0, w, 2):
                if is_send(*px[x, y]):
                    cells.setdefault((x // 40, y // 40), []).append((x, y))
        if not cells:
            return None
        cluster = max(cells.values(), key=len)
        xs = [p[0] for p in cluster]
        ys = [p[1] for p in cluster]
        pt = ((min(xs) + max(xs)) / 2 / self.scale, (min(ys) + max(ys)) / 2 / self.scale)
        self._send_key_pt = pt
        return pt

    # ---------- 输入框 / 发送 ----------
    def find_input(self):
        """定位输入框（多个 TextView 时优先取最靠底部者）。"""
        cands = self.find_all("visible == true AND enabled == true", "XCUIElementTypeTextView")
        best, best_y = None, -1.0
        for eid in cands:
            frame = self.element_frame(eid)
            y = frame[1] if frame else -1.0
            if y > best_y:
                best_y, best = y, eid
        return best

    def wait_input(self, tries=8, interval=1.0):
        """等输入框出现并返回元素 id。"""
        for _ in range(tries):
            tv = self.find_input()
            if tv:
                return tv
            time.sleep(interval)
        return None

    def type_and_verify(self, tv, text):
        self.click_element(tv)
        time.sleep(0.8)
        self.set_value(tv, text)
        for _ in range(5):
            got = self.element_text(tv)
            if got == text:
                return True
            time.sleep(0.5)
        raise WDAError(f"输入校验失败: 期望 {text!r} 实际 {got!r}")

    def press_send(self, send_label="发送"):
        """发送：按 label 找按钮；frame 异常时像素定位兜底。"""
        btn = self.find(
            f"name == {predicate_literal(send_label)} AND visible == true",
            "XCUIElementTypeButton")
        if btn:
            frame = self.element_frame(btn)
            _, lh = self._logical_window_size()
            if frame and lh and frame[1] > lh * 0.5:
                self.click_element(btn)
                return
        pt = self.locate_send_key()
        if pt:
            self.tap(pt[0], pt[1])
            return
        if btn:
            self.click_element(btn)  # 兜底
            return
        raise WDAError(f"找不到发送键（label={send_label}）")

    def _input_cleared(self):
        """重新定位输入框并确认已清空（发送成功信号）。"""
        tv = self.find_input()
        if tv is None:
            return False
        return self.element_text(tv) == ""
