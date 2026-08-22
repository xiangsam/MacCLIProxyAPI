#!/usr/bin/env python3
"""Probe whether DeepSeek implements Codex's remote-compaction endpoint.

Remote compaction is what Codex calls when history fills up: it POSTs to
{base}/v1/responses/compact (a.k.a. /responses/compact) instead of doing a
local summarization. Codex gates this on provider name == "OpenAI" and never
falls back, so whether the upstream actually answers the endpoint matters.

This script only checks reachability + endpoint support; it never runs a full
compaction. Config comes from env vars or the app's provider-secrets.json.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
KEY = os.environ.get("DEEPSEEK_API_KEY", "")

SECRETS = os.path.expanduser(
    "~/Library/Application Support/com.maccliproxyapi/provider-secrets.json"
)

def find_key_in_secrets():
    if not os.path.exists(SECRETS):
        return ""
    try:
        data = json.load(open(SECRETS))
    except Exception:
        return ""
    for k, v in data.items():
        if "deepseek" in k.lower():
            return v
    return ""

def request(method, url, body=None, timeout=30):
    headers = {
        "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json",
    }
    req = urllib.request.Request(
        url, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, raw[:500]
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        return e.code, raw[:500]
    except Exception as e:  # network / DNS / TLS
        return -1, str(e)

def main():
    global KEY
    if not KEY:
        KEY = find_key_in_secrets()
    if not KEY:
        print("No DeepSeek API key found (env DEEPSEEK_API_KEY or provider-secrets.json)")
        sys.exit(2)
    print(f"Base : {BASE}")
    print(f"Key  : {KEY[:6]}...{KEY[-4:]}")

    # 1) Reachability: models list endpoint.
    st, body = request("GET", f"{BASE}/v1/models")
    print(f"\n[1] GET {BASE}/v1/models -> {st}")
    models = []
    try:
        models = [m.get("id") for m in json.loads(body).get("data", [])]
        print(f"    models: {models}")
    except Exception:
        print(f"    body: {body}")

    model = os.environ.get("DEEPSEEK_MODEL", "")
    if not model:
        for cand in ("deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"):
            if cand in models:
                model = cand
                break
        model = model or "deepseek-chat"

    # Minimal, realistic compaction body (Codex compact_remote_request shape).
    body = {
        "model": model,
        "instructions": "You are Codex, a coding agent.",
        "messages": [{"role": "user", "content": "Hello"}],
        "context": [{"type": "input_text", "text": "Hello"}],
        "max_output_tokens": 64,
    }

    # 2) The endpoint(s) Codex uses for remote compaction.
    candidates = [
        f"{BASE}/v1/responses/compact",
        f"{BASE}/responses/compact",
        f"{BASE}/v1/compact",
    ]
    results = []
    for url in candidates:
        st, text = request("POST", url, body=body)
        print(f"\n[2] POST {url} -> {st}")
        print(f"    body: {text}")
        results.append((url, st, text))

    supported = any(st == 200 for _, st, _ in results)
    if supported:
        print("\nVERDICT: DeepSeek SUPPORTS the compact interface (HTTP 200 on /responses/compact).")
    else:
        print("\nVERDICT: DeepSeek does NOT implement the compact interface "
              "(no 200 on any candidate; see status codes above).")

if __name__ == "__main__":
    main()

