#!/usr/bin/env python3
"""Records Brave devtools events to /tmp/brave-console.log for later analysis."""
import json, time
import urllib.request
import websocket

LOG = open("/tmp/brave-console.log", "a", buffering=1)

def out(s):
    LOG.write(f"{time.strftime('%H:%M:%S')} {s}\n")

def connect():
    tabs = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json").read())
    page = next((t for t in tabs if t.get("type") == "page"), tabs[0])
    return websocket.create_connection(page["webSocketDebuggerUrl"], timeout=10)

while True:
    try:
        ws = connect()
        out("--- connected ---")
        for i, method in enumerate(["Runtime.enable", "Console.enable", "Log.enable", "Network.enable"]):
            ws.send(json.dumps({"id": i + 1, "method": method}))
        ws.settimeout(None)
        # Map requestId -> URL so we can report URL on later failure events
        req_urls = {}
        while True:
            m = json.loads(ws.recv())
            method = m.get("method", "")
            p = m.get("params", {})
            if method == "Network.requestWillBeSent":
                req_urls[p.get("requestId")] = p.get("request", {}).get("url", "")
            elif method == "Runtime.consoleAPICalled":
                args = [a.get("value", a.get("description", "?")) for a in p.get("args", [])]
                out(f"[{p.get('type')}] {' '.join(map(str, args))[:300]}")
            elif method == "Log.entryAdded":
                e = p.get("entry", {})
                out(f"[log/{e.get('level')}] {e.get('text', '')[:300]} :: {e.get('url', '')[:200]}")
            elif method == "Runtime.exceptionThrown":
                e = p.get("exceptionDetails", {})
                desc = e.get("exception", {}).get("description", "")
                out(f"[EXCEPTION] {e.get('text', '')} :: {desc[:400]}")
            elif method == "Network.loadingFailed":
                rid = p.get("requestId")
                url = req_urls.pop(rid, "<unknown>")
                out(f"[net-FAIL] {p.get('errorText')} :: {url[:200]}")
            elif method == "Network.responseReceived":
                r = p.get("response", {})
                if r.get("status", 200) >= 400:
                    out(f"[net-{r.get('status')}] {r.get('url', '')[:200]}")
    except Exception as e:
        out(f"--- disconnect: {e} ---")
        time.sleep(3)
