#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WDA 微信自动发送脚本（优化版）

针对实测问题优化：
1. 慢：不再 GET /source 全量 dump 元素树（微信树 ~460KB，一次约 20s），
   全部改用 POST /session/:id/element 谓词定向查询 + 元素文本回读校验。
2. 不准：元素级定位（type+name+visible+enabled 谓词），每步回读校验；
   发送键在 iOS 18 下 WDA 上报的键盘 frame 整体偏移，因此用截图+像素聚类
   定位发送键实心块的真实坐标（仅此一步用坐标，其余全部走元素）。
3. 闪退/会话失效：App 被关、WDA 会话失效时自动 DELETE 会话重建（重新拉起
   微信）并整流程重试一次，不再因陈旧会话导致失败或表现异常。

用法:
  python3 scripts/wda_send.py --wda http://192.168.20.235:8100 \
      --contact "迪迦Hanson" --text "你好"
可选:
  --session-id XXX   复用已有 WDA 会话（加速；无效会自动重建）
  --scale N          截图像素/逻辑点 比例（默认自动: 截图宽/393）
  --max-retry N      会话重建后重试次数（默认 1）
  --verbose          打印每步耗时

依赖: Python3 标准库; 发送键像素定位需要 Pillow（无则退回元素点击并告警）。
"""

import argparse
import base64
import io
import json
import sys
import time
import urllib.error
import urllib.request

WECHAT_BUNDLE = "com.tencent.xin"


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
        """W3C pointer 点击（本版 WDA 不支持 /tap、/keys）。"""
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
        """定位键盘'发送'键中心（逻辑点）。优先缓存。"""
        if self._send_key_pt:
            return self._send_key_pt
        try:
            from PIL import Image
        except ImportError:
            print("警告: 未安装 Pillow，发送键退回元素点击（iOS18 键盘 frame 偏移可能点不准）",
                  file=sys.stderr)
            return None
        png = self.screenshot_bytes()
        im = Image.open(io.BytesIO(png)).convert("RGB")
        w, h = im.size
        if not self.scale:
            self.scale = w / 393.0  # 竖屏 393pt 宽
        px = im.load()

        def is_send(r, g, b):
            green = g > 120 and g > r + 40 and g > b + 40
            orange = r > 190 and 90 < g < 200 and b < 130 and r > g + 30
            return green or orange

        # 键盘区域：底部 32%，右侧 55%
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

    # ---------- 业务流程 ----------
    def open_chat(self, contact):
        """从聊天列表进入会话；找不到则走搜索。"""
        cell = self.find(f"name CONTAINS '{contact}' AND visible == true", "XCUIElementTypeCell")
        if cell:
            self.click_element(cell)
            return
        # 搜索流程
        sf = self.find("name == '搜索' AND visible == true", "XCUIElementTypeSearchField")
        if not sf:
            raise WDAError("找不到搜索框，且聊天列表无目标会话")
        self.click_element(sf)
        time.sleep(1)
        self.set_value(sf, contact)
        for _ in range(10):
            time.sleep(1)
            hit = self.find(f"name CONTAINS '{contact}' AND visible == true", "XCUIElementTypeCell")
            if hit:
                self.click_element(hit)
                return
        raise WDAError(f"搜索 '{contact}' 无结果")

    def wait_input(self, tries=8, interval=1.0):
        """等聊天输入框出现并返回元素 id。"""
        for _ in range(tries):
            tv = self.find("type == 'XCUIElementTypeTextView' AND visible == true AND enabled == true")
            if tv:
                return tv
            time.sleep(interval)
        return None

    def type_and_verify(self, tv, text):
        self.click_element(tv)
        time.sleep(0.8)
        self.set_value(tv, text)
        # 回读校验
        for _ in range(5):
            got = self.element_text(tv)
            if got == text:
                return True
            time.sleep(0.5)
        raise WDAError(f"输入校验失败: 期望 {text!r} 实际 {got!r}")

    def press_send(self, tv):
        """发送：元素优先，frame 异常(键盘偏移)则像素定位+坐标点击。"""
        btn = self.find("name == '发送' AND visible == true", "XCUIElementTypeButton")
        if btn:
            frame = self.element_frame(btn)
            # iOS18 键盘 frame 整体偏移：y 落在键盘区下半才可信
            if frame and frame[1] > 400:
                self.click_element(btn)
                return
        pt = self.locate_send_key()
        if pt:
            self.tap(pt[0], pt[1])
            return
        if btn:
            self.click_element(btn)  # 兜底
            return
        raise WDAError("找不到发送键")

    def send(self, contact, text, max_retry=1):
        last = None
        for attempt in range(max_retry + 1):
            try:
                if not self.alive():
                    self.create_session(WECHAT_BUNDLE)
                if self.verbose:
                    print(f"会话 {self.session_id}", file=sys.stderr)
                self.open_chat(contact)
                tv = self.wait_input()
                if not tv:
                    raise WDAError("输入框未出现")
                self.type_and_verify(tv, text)
                self.press_send(tv)
                # 校验发送成功：输入框清空
                for _ in range(8):
                    if self.element_text(tv) == "":
                        return True
                    time.sleep(0.5)
                raise WDAError("发送后输入框未清空")
            except WDAError as e:
                last = e
                if e.session_invalid and attempt < max_retry:
                    print(f"会话失效，重建会话重试: {e}", file=sys.stderr)
                    try:
                        if self.session_id:
                            self._request("DELETE", f"/session/{self.session_id}")
                    except Exception:
                        pass
                    self.session_id = None
                    continue
                raise
        raise last


def main():
    ap = argparse.ArgumentParser(description="WDA 微信自动发送")
    ap.add_argument("--wda", required=True, help="WDA 地址，如 http://192.168.20.235:8100")
    ap.add_argument("--contact", required=True, help="联系人/群名，如 迪迦Hanson")
    ap.add_argument("--text", required=True, help="消息内容，如 你好")
    ap.add_argument("--session-id", default=None)
    ap.add_argument("--scale", type=float, default=None)
    ap.add_argument("--max-retry", type=int, default=1)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    client = WDAClient(args.wda, verbose=args.verbose)
    client.scale = args.scale
    if args.session_id:
        client.session_id = args.session_id

    t0 = time.time()
    ok = client.send(args.contact, args.text, max_retry=args.max_retry)
    print(f"OK 已发送 -> {args.contact}: {args.text}  总耗时 {time.time()-t0:.1f}s"
          + (f"  会话 {client.session_id}" if client.session_id else ""))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
