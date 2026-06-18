#!/usr/bin/env python3
import argparse
import json
import re
import sys
import time
import urllib.request

try:
    import websocket
except ImportError:
    sys.stderr.write("websocket-client not installed; run: pip3 install --user websocket-client\n")
    sys.exit(2)


def http_json(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


EXTRACT_JS = r"""
(function() {
  function pct(label) {
    var text = document.body.innerText;
    var idx = text.toLowerCase().indexOf(label.toLowerCase());
    if (idx < 0) idx = text.indexOf(label);
    if (idx < 0) return null;
    var window = text.substring(idx, Math.min(idx + 150, text.length));
    var m = window.match(/(\d{1,3})\s*%/);
    if (!m) return null;
    var v = parseInt(m[1], 10);
    if (v < 0 || v > 999) return null;
    return v;
  }
  function resetFor(label) {
    var text = document.body.innerText;
    var idx = text.toLowerCase().indexOf(label.toLowerCase());
    if (idx < 0) idx = text.indexOf(label);
    if (idx < 0) return null;
    var after = text.substring(idx + label.length, Math.min(idx + label.length + 300, text.length));
    var lines = after.split('\n');
    for (var i = 0; i < Math.min(lines.length, 6); i++) {
      var line = lines[i].trim();
      if (line.endsWith('後にリセット')) {
        var t = line.replace(/後にリセット$/, '').trim();
        if (t && t.length <= 40 && !/\d\s*%/.test(t)) return t;
      }
      if (line.endsWith('にリセット')) {
        var t = line.replace(/にリセット$/, '').trim();
        if (t && t.length <= 40 && !/\d\s*%/.test(t)) return t;
      }
      if (/resets in\s.+$/i.test(line)) {
        var t = line.replace(/^.*resets in\s+/i, '').trim();
        if (t && t.length <= 40 && !/\d\s*%/.test(t)) return t;
      }
    }
    return null;
  }
  function moneyUsed(re) {
    var m = document.body.innerText.match(re);
    if (!m) return null;
    var v = parseFloat(m[1].replace(/,/g, ""));
    return isNaN(v) ? null : v;
  }
  function moneyCap(re) {
    var m = document.body.innerText.match(re);
    if (!m) return null;
    var v = parseFloat(m[1].replace(/,/g, ""));
    return isNaN(v) ? null : v;
  }
  var text = document.body ? document.body.innerText : "";
  var planMatch = text.match(/Max\s*\(([^)]+)\)/);
  var planTier = null;
  if (planMatch) {
    var raw = planMatch[1].trim().toLowerCase();
    if (/^\d+/.test(raw)) planTier = "max" + raw.replace(/\s+/g, "");
    else planTier = raw;
  } else if (/Pro\b/.test(text)) {
    planTier = "pro";
  }
  return JSON.stringify({
    ok: true,
    fetched_at: new Date().toISOString(),
    plan_tier: planTier,
    session_pct: pct("Current session") || pct("\u73fe\u5728\u306e\u30bb\u30c3\u30b7\u30e7\u30f3"),
    session_reset: resetFor("Current session") || resetFor("\u73fe\u5728\u306e\u30bb\u30c3\u30b7\u30e7\u30f3"),
    weekly_all_pct: pct("All models") || pct("\u3059\u3079\u3066\u306e\u30e2\u30c7\u30eb"),
    weekly_sonnet_pct: pct("Sonnet only") || pct("Sonnet\u306e\u307f"),
    weekly_reset: resetFor("All models") || resetFor("\u3059\u3079\u3066\u306e\u30e2\u30c7\u30eb"),
    monthly_all_pct: pct("Monthly") || pct("\u6708\u9593"),
    monthly_reset: resetFor("Credits") || resetFor("\u5229\u7528\u30af\u30ec\u30b8\u30c3\u30c8") || resetFor("Monthly") || resetFor("\u6708\u9593"),
    additional_used: moneyUsed(/\$\s*([\d.,]+)\s*(?:used|\u4f7f\u7528\u6d3e|\/)/i),
    additional_cap: moneyCap(/\$\s*([\d.,]+)\s*(?:cap|limit|\u4e0a\u9650)/i),
    page_excerpt: text.substring(0, 600),
    url: location.href
  });
})()
"""


def probe_targets(port):
    return http_json(f"http://127.0.0.1:{port}/json", timeout=5)


def attach_session(bws, target_id):
    bws.send(json.dumps({
        "id": 1,
        "method": "Target.attachToTarget",
        "params": {"targetId": target_id, "flatten": True},
    }))
    while True:
        r = json.loads(bws.recv())
        if r.get("id") == 1:
            return r["result"]["sessionId"]


def send_command(bws, method, params, session_id, msg_id):
    bws.send(json.dumps({
        "id": msg_id,
        "sessionId": session_id,
        "method": method,
        "params": params,
    }))


def wait_for_response(bws, target_id, msg_id, timeout=20):
    deadline = time.time() + timeout
    bws.settimeout(1.0)
    while time.time() < deadline:
        try:
            raw = bws.recv()
        except Exception:
            continue
        try:
            r = json.loads(raw)
        except Exception:
            continue
        if r.get("id") == msg_id:
            return r
    return None


def navigate_and_extract(ws_url, target_url, timeout_s):
    browser_ws = ws_url
    if not browser_ws.endswith("/devtools/browser/" + browser_ws.rsplit("/", 1)[-1]):
        targets = probe_targets(9222)
        for t in targets:
            if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                browser_ws = t["webSocketDebuggerUrl"]
                break
    bws = websocket.create_connection(browser_ws, timeout=timeout_s)
    msg_id = [0]
    try:
        msg_id[0] += 1
        bws.send(json.dumps({
            "id": msg_id[0],
            "method": "Target.createTarget",
            "params": {"url": target_url},
        }))
        create_resp = wait_for_response(bws, None, msg_id[0], timeout=10)
        if not create_resp or "result" not in create_resp:
            return {"ok": False, "error": "ws_error", "fetched_at": _now()}
        target_id = create_resp["result"]["targetId"]
        attach = attach_session(bws, target_id)
        for domain in ("Page.enable", "Runtime.enable"):
            msg_id[0] += 1
            send_command(bws, domain, {}, attach, msg_id[0])
            wait_for_response(bws, None, msg_id[0], timeout=5)
        msg_id[0] += 1
        send_command(bws, "Page.navigate", {"url": target_url}, attach, msg_id[0])
        wait_for_response(bws, None, msg_id[0], timeout=10)
        deadline = time.time() + timeout_s
        loaded = False
        while time.time() < deadline:
            try:
                bws.settimeout(1.0)
                raw = bws.recv()
            except Exception:
                continue
            try:
                r = json.loads(raw)
            except Exception:
                continue
            if r.get("method") == "Page.loadEventFired":
                loaded = True
                break
        if not loaded:
            return {"ok": False, "error": "page_load_timeout", "fetched_at": _now()}
        time.sleep(8.0)
        msg_id[0] += 1
        send_command(bws, "Runtime.evaluate", {
            "expression": EXTRACT_JS,
            "returnByValue": True,
            "awaitPromise": False,
        }, attach, msg_id[0])
        eval_resp = wait_for_response(bws, None, msg_id[0], timeout=10)
        if not eval_resp or "result" not in eval_resp:
            return {"ok": False, "error": "ws_error", "fetched_at": _now()}
        val = eval_resp["result"]["result"].get("value")
        if not val:
            return {"ok": False, "error": "extract_regex_no_match", "fetched_at": _now()}
        try:
            data = json.loads(val)
        except Exception:
            return {"ok": False, "error": "extract_regex_no_match", "fetched_at": _now()}
        url = data.get("url", "")
        if "/login" in url or "/sign-in" in url or "/logout" in url or "/signup" in url:
            return {"ok": False, "error": "not_logged_in", "fetched_at": _now()}
        if data.get("session_pct") is None and data.get("weekly_all_pct") is None:
            return {
                "ok": False,
                "error": "extract_regex_no_match",
                "fetched_at": _now(),
                "page_excerpt": data.get("page_excerpt", ""),
                "url": url,
            }
        data["ok"] = True
        if "fetched_at" not in data:
            data["fetched_at"] = _now()
        return data
    finally:
        try:
            bws.close()
        except Exception:
            pass


def _now():
    import datetime
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ws-url", required=False, default="")
    p.add_argument("--target-url", default="https://claude.ai/settings/usage")
    p.add_argument("--timeout", type=int, default=15)
    p.add_argument("--port", type=int, default=9222)
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()

    if args.self_test:
        fixture = {
            "ok": True,
            "fetched_at": _now(),
            "plan_tier": "5x",
            "session_pct": 42,
            "weekly_all_pct": 18,
            "weekly_sonnet_pct": 12,
            "monthly_all_pct": 4,
            "session_reset": "1h 23m",
            "weekly_reset": "4d 12h",
            "monthly_reset": "23d 4h",
            "additional_used": 0.0,
            "additional_cap": 68.41,
        }
        sys.stdout.write(json.dumps(fixture, separators=(",", ":")))
        return

    ws_url = args.ws_url
    if not ws_url:
        try:
            version = http_json(f"http://127.0.0.1:{args.port}/json/version", timeout=3)
            ws_url = version["webSocketDebuggerUrl"]
        except Exception as e:
            sys.stdout.write(json.dumps({
                "ok": False,
                "error": "ws_error",
                "fetched_at": _now(),
                "detail": str(e),
            }))
            return

    result = navigate_and_extract(ws_url, args.target_url, args.timeout)
    sys.stdout.write(json.dumps(result, separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main()
