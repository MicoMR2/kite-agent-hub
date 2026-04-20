#!/usr/bin/env python3
"""Reference BYO-LLM runner for Kite Agent Hub.

Polls the platform for the agent's system prompt + current market
context, hands the prompt to a local Ollama server, parses the JSON
decision, and POSTs it to /api/v1/trades. Swap the OLLAMA_MODEL for
any model Ollama supports.

Env:
    KAH_AGENT_TOKEN  — agent api_token from the dashboard (required)
    KAH_BASE_URL     — platform URL (default: http://localhost:4000)
    OLLAMA_BASE_URL  — local Ollama server (default: http://localhost:11434)
    OLLAMA_MODEL     — local model tag (default: qwen2.5:7b)
"""

import json
import os
import sys
import time
import urllib.request

KAH_BASE = os.environ.get("KAH_BASE_URL", "http://localhost:4000").rstrip("/")
AGENT_TOKEN = os.environ.get("KAH_AGENT_TOKEN")
OLLAMA_BASE = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434").rstrip("/")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b")

if not AGENT_TOKEN:
    sys.exit("error: KAH_AGENT_TOKEN not set")


def http(method, url, body=None):
    headers = {
        "Authorization": f"Bearer {AGENT_TOKEN}",
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def ollama_chat(prompt):
    req = urllib.request.Request(
        f"{OLLAMA_BASE}/api/chat",
        data=json.dumps(
            {"model": OLLAMA_MODEL, "stream": False, "messages": [{"role": "user", "content": prompt}]}
        ).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode())["message"]["content"]


def tick():
    # 1. Pull the agent's current system prompt + market context
    ctx = http("GET", f"{KAH_BASE}/api/v1/agents/me")
    prompt = ctx.get("system_prompt")
    if not prompt:
        print("no system_prompt in /agents/me — skipping tick")
        return

    # 2. Ask the local model
    raw = ollama_chat(prompt).strip()
    # Strip markdown fences the model sometimes adds
    if raw.startswith("```"):
        raw = raw.split("```", 2)[1].lstrip("json").strip()
    decision = json.loads(raw)

    if decision.get("action") in ("hold", None):
        print(f"hold: {decision.get('reason', 'no signal')}")
        return

    # 3. POST the trade
    resp = http("POST", f"{KAH_BASE}/api/v1/trades", decision)
    print(f"trade queued: {resp}")


if __name__ == "__main__":
    while True:
        try:
            tick()
        except Exception as e:
            print(f"tick failed: {e}")
        time.sleep(30)
