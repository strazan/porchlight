#!/usr/bin/env python3
"""A tiny stdio MCP server for tests.

tools: echo (returns its args), slow (sends progress, then answers after `seconds`).
Exits on `tools/call` of `crash`. Counts initialize calls in the `stats` tool.
Also one prompt (`greet`) and one resource (`fake://<name>/readme`). The server's name
comes from FAKE_NAME so tests can tell several apart.
"""
import json
import os
import sys
import threading
import time

NAME = os.environ.get("FAKE_NAME", "fake")
lock = threading.Lock()
initialized = {"count": 0}


def send(msg):
    with lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


def result(id, value):
    send({"jsonrpc": "2.0", "id": id, "result": value})


def text(value):
    return {"content": [{"type": "text", "text": value}]}


def slow(id, params):
    token = params.get("_meta", {}).get("progressToken")
    seconds = params.get("arguments", {}).get("seconds", 0.2)
    if token is not None:
        send({"jsonrpc": "2.0", "method": "notifications/progress",
              "params": {"progressToken": token, "progress": 1, "total": 2}})
    time.sleep(seconds)
    result(id, text("done"))


for line in sys.stdin:
    msg = json.loads(line)
    method, id, params = msg.get("method"), msg.get("id"), msg.get("params", {})
    if id is None:
        continue
    if method == "initialize":
        initialized["count"] += 1
        result(id, {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}, "prompts": {}, "resources": {}},
                    "serverInfo": {"name": NAME, "version": "1"}})
    elif method == "tools/list":
        result(id, {"tools": [{"name": "echo", "inputSchema": {"type": "object"},
                               "annotations": {"readOnlyHint": True}}]})
    elif method == "tools/call":
        name = params.get("name")
        if name == "echo":
            result(id, text(json.dumps({"id": id, "args": params.get("arguments"), "server": NAME})))
        elif name == "slow":
            threading.Thread(target=slow, args=(id, params)).start()
        elif name == "stats":
            result(id, text(json.dumps({"initialize_count": initialized["count"]})))
        elif name == "crash":
            sys.exit(1)
    elif method == "prompts/list":
        result(id, {"prompts": [{"name": "greet"}]})
    elif method == "prompts/get":
        result(id, {"messages": [{"role": "user", "content": {"type": "text", "text": f"hello from {NAME}"}}]})
    elif method == "resources/list":
        result(id, {"resources": [{"uri": f"fake://{NAME}/readme", "name": "readme"}]})
    elif method == "resources/read":
        result(id, {"contents": [{"uri": params["uri"], "text": NAME}]})
    else:
        send({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "unknown"}})
