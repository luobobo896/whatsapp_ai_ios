#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WDA WhatsApp 群发：把「消息内容 + 手机号列表」逐条发到对应 WhatsApp 会话。

模拟平台下发的数据面：平台侧拿到设备上报的 wdaUrl 后，直接调本脚本/本逻辑，
经 WDA 在真机上打开 WhatsApp -> 打开对应手机号会话 -> 发送 -> 校验 -> 汇总。

上报给平台的结构化报告（stdout JSON）：
  meta.summary   total / sent / failed / durationMs / avgPerItemMs
  items[]        phone / e164 / status / durationMs / attempts / error / steps[]

用法:
  python3 scripts/wda_whatsapp_broadcast.py \
      --wda http://<手机IP>:8100 \
      --text "某商品价格实惠，现在只要100元即可" \
      --phones 18078526388,17688540775

  # 平台 payload（JSON，支持 stdin）
  echo '{"text":"...","phones":["18078526388","17688540775"]}' \
    | python3 scripts/wda_whatsapp_broadcast.py --wda http://<手机IP>:8100 --payload -

可选:
  --country-code 86    手机号所属国家码（默认 86）
  --send-labels Send,发送  发送键 accessibility label 候选
  --bundle-id X        WhatsApp bundle id（默认 net.whatsapp.WhatsApp）
  --check              预检：只验证 WDA 就绪 + WhatsApp 可拉起，不发送
  --max-retry 1        会话失效后重建重试次数
  --session-id XXX     复用已有 WDA 会话
  --out report.json    把报告写入文件（默认只打印 stdout）
  --verbose            打印每步耗时
"""

import argparse
import datetime
import json
import re
import sys
import time
import urllib.parse

sys.path.insert(0, __import__("os").path.dirname(__file__))
from wda_client import WDAClient, WDAError, predicate_literal  # noqa: E402

WHATSAPP_BUNDLE = "net.whatsapp.WhatsApp"


def _iso_now():
    return datetime.datetime.now().isoformat(timespec="milliseconds")


def normalize_e164(phone, country_code="86"):
    """把任意格式手机号规范化成 E.164 数字串（不含 +）。

    例（中国）：18078526388 -> 8618078526388；+8618078526388 -> 8618078526388。
    """
    digits = re.sub(r"\D", "", phone or "")
    if not digits:
        raise ValueError(f"手机号为空: {phone!r}")
    if digits.startswith("00"):
        digits = digits[2:]
    cc = str(country_code)
    if digits.startswith(cc) and len(digits) > len(cc) + 4:
        return digits
    digits = digits.lstrip("0")
    if digits.startswith(cc):
        return digits
    return cc + digits


class WhatsAppBroadcaster:
    def __init__(self, wda_url, country_code="86", send_labels=None,
                 max_retry=1, verbose=False, bundle_id=WHATSAPP_BUNDLE):
        self.client = WDAClient(wda_url, verbose=verbose)
        self.country_code = str(country_code)
        self.send_labels = send_labels or ["Send", "发送"]
        self.max_retry = max_retry
        self.verbose = verbose
        self.bundle_id = bundle_id

    # ---------- 执行步骤日志 ----------
    @staticmethod
    def _record_step(item, name, started, error=None):
        entry = {"step": name, "ms": int((time.time() - started) * 1000), "t": _iso_now()}
        if error:
            entry["error"] = error
        item["steps"].append(entry)
        return time.time()

    def _ensure_session(self):
        if not self.client.alive():
            self.client.create_session(self.bundle_id)
        return self.client.session_id

    def check(self):
        """预检：WDA 是否就绪、WhatsApp 是否能拉起（不真正发消息）。"""
        result = {
            "wda": self.client.base,
            "bundleId": self.bundle_id,
            "wdaReachable": False,
            "wdaReady": False,
            "sessionCreated": False,
            "sessionId": None,
            "error": None,
        }
        try:
            status, payload = self.client._request("GET", "/status")
            result["wdaReachable"] = status == 200
            value = payload.get("value") or {}
            result["wdaReady"] = bool(value.get("ready"))
            if not result["wdaReady"]:
                result["error"] = f"WDA /status 未 ready: {payload}"
                return result
            sid = self.client.create_session(self.bundle_id)
            result["sessionCreated"] = bool(sid)
            result["sessionId"] = sid
        except Exception as e:
            result["error"] = str(e)
        return result

    def _open_chat_with_text(self, e164, text):
        query = urllib.parse.urlencode({"phone": e164, "text": text})
        url = f"whatsapp://send?{query}"
        self.client.open_url(url, bundle_id=self.bundle_id, idle_timeout_ms=3000)

    def _tap_send(self):
        for label in self.send_labels:
            btn = self.client.find(
                f"name == {predicate_literal(label)} AND visible == true",
                "XCUIElementTypeButton")
            if not btn:
                continue
            frame = self.client.element_frame(btn)
            _, lh = self.client._logical_window_size()
            if frame and lh and frame[1] > lh * 0.5:
                self.client.click_element(btn)
                return
        pt = self.client.locate_send_key()
        if pt:
            self.client.tap(pt[0], pt[1])
            return
        raise WDAError(f"找不到 WhatsApp 发送键（labels={self.send_labels}）")

    def send_to_phone(self, phone, text):
        """向单个手机号发一条文本，返回带耗时/步骤日志的结果 dict。

        单个手机号归一化失败只记为该条 failed，不阻断整批。
        """
        item = {
            "phone": phone,
            "e164": None,
            "status": "failed",
            "durationMs": 0,
            "attempts": 0,
            "error": None,
            "steps": [],
        }
        started = time.time()
        try:
            e164 = normalize_e164(phone, self.country_code)
        except Exception as e:
            item["durationMs"] = int((time.time() - started) * 1000)
            item["error"] = str(e)
            self._record_step(item, "error", started, error=str(e))
            return item
        item["e164"] = e164
        last = None
        for attempt in range(self.max_retry + 1):
            item["attempts"] = attempt + 1
            mark = time.time()
            try:
                self._ensure_session()
                mark = self._record_step(item, "ensure_session", mark)
                self._open_chat_with_text(e164, text)
                mark = self._record_step(item, "open_chat", mark)
                tv = self.client.wait_input()
                if not tv:
                    raise WDAError(f"[{e164}] 输入框未出现")
                mark = self._record_step(item, "input_ready", mark)
                if self.client.element_text(tv) != text:
                    self.client.type_and_verify(tv, text)
                mark = self._record_step(item, "text_verified", mark)
                self._tap_send()
                mark = self._record_step(item, "send_tapped", mark)
                for _ in range(8):
                    if self.client._input_cleared():
                        item["status"] = "sent"
                        self._record_step(item, "sent_verified", mark)
                        break
                    time.sleep(0.5)
                if item["status"] != "sent":
                    raise WDAError(f"[{e164}] 发送后输入框未清空")
            except WDAError as e:
                last = e
                self._record_step(item, "error", mark, error=str(e))
                if e.session_invalid and attempt < self.max_retry:
                    if self.verbose:
                        print(f"[{e164}] 会话失效，重建重试: {e}", file=sys.stderr)
                    try:
                        if self.client.session_id:
                            self.client._request("DELETE", f"/session/{self.client.session_id}")
                    except Exception:
                        pass
                    self.client.session_id = None
                    continue
                break
            except Exception as e:  # 归一化/编程错误，不重试
                last = e
                self._record_step(item, "error", mark, error=str(e))
                break
            break

        item["durationMs"] = int((time.time() - started) * 1000)
        if item["status"] != "sent":
            item["error"] = str(last)
        return item

    def broadcast(self, phones, text):
        """群发并返回可上报平台的结构化报告。"""
        started_at = _iso_now()
        t0 = time.time()
        items = [self.send_to_phone(phone, text) for phone in phones]
        duration_ms = int((time.time() - t0) * 1000)
        sent = sum(1 for it in items if it["status"] == "sent")
        failed = len(items) - sent
        return {
            "meta": {
                "wda": self.client.base,
                "bundleId": WHATSAPP_BUNDLE,
                "startedAt": started_at,
                "endedAt": _iso_now(),
                "durationMs": duration_ms,
            },
            "summary": {
                "total": len(items),
                "sent": sent,
                "failed": failed,
                "durationMs": duration_ms,
                "avgPerItemMs": int(duration_ms / len(items)) if items else 0,
            },
            "items": items,
        }


def _load_payload(path_or_dash):
    data = sys.stdin.read() if path_or_dash == "-" else open(path_or_dash, encoding="utf-8").read()
    payload = json.loads(data)
    text = payload.get("text")
    phones = payload.get("phones") or payload.get("numbers") or []
    if not text or not isinstance(phones, list) or not phones:
        raise SystemExit("payload 需要包含 text 与非空 phones 数组")
    return text, [str(p) for p in phones]


def main():
    ap = argparse.ArgumentParser(description="WDA WhatsApp 群发")
    ap.add_argument("--wda", required=True, help="WDA 地址，如 http://<手机IP>:8100")
    ap.add_argument("--text", help="消息内容")
    ap.add_argument("--phones", help="手机号列表，逗号/空格分隔，如 18078526388,17688540775")
    ap.add_argument("--payload", help="平台 payload：JSON 文件路径，或 '-' 读 stdin（含 text+phones）")
    ap.add_argument("--country-code", default="86", help="手机号国家码（默认 86）")
    ap.add_argument("--send-labels", default="Send,发送", help="发送键 label 候选，逗号分隔")
    ap.add_argument("--bundle-id", default=WHATSAPP_BUNDLE, help=f"WhatsApp bundle id（默认 {WHATSAPP_BUNDLE}）")
    ap.add_argument("--check", action="store_true", help="预检：只验证 WDA 就绪 + WhatsApp 可拉起，不发送")
    ap.add_argument("--session-id", default=None)
    ap.add_argument("--scale", type=float, default=None)
    ap.add_argument("--max-retry", type=int, default=1)
    ap.add_argument("--out", default=None, help="报告输出文件路径（默认只打印 stdout）")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    broadcaster = WhatsAppBroadcaster(
        args.wda,
        country_code=args.country_code,
        send_labels=[s for s in args.send_labels.split(",") if s],
        max_retry=args.max_retry,
        verbose=args.verbose,
        bundle_id=args.bundle_id,
    )
    broadcaster.client.scale = args.scale
    if args.session_id:
        broadcaster.client.session_id = args.session_id

    if args.check:
        result = broadcaster.check()
        print(json.dumps(result, ensure_ascii=False, indent=2))
        sys.exit(0 if (result["wdaReady"] and result["sessionCreated"]) else 1)

    if args.payload:
        text, phones = _load_payload(args.payload)
    else:
        text = args.text
        if not text:
            raise SystemExit("需要 --text，或 --payload 指定平台 payload")
        if not args.phones:
            raise SystemExit("需要 --phones，或 --payload 指定平台 payload")
        phones = [p for p in re.split(r"[,\s]+", args.phones) if p]

    if not phones:
        raise SystemExit("手机号列表为空")

    report = broadcaster.broadcast(phones, text)
    report_json = json.dumps(report, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(report_json + "\n")
    print(report_json)
    sys.exit(0 if report["summary"]["failed"] == 0 else 1)


if __name__ == "__main__":
    main()
