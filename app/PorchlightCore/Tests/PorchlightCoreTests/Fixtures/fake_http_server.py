#!/usr/bin/env python3
"""A tiny Streamable HTTP MCP server for tests, shaped like Obsidian's.

Listens on a free port (printed as the first line of stdout) at /mcp.
- Requires `Authorization: Bearer test-key`.
- `initialize` assigns an `Mcp-Session-Id`; later requests must send it (404 otherwise).
- `tools/call` answers as SSE when the client accepts it, with a progress event first
  if the request has a progress token. Tool `restart` forgets all sessions.
- Counts initialize calls in the `stats` tool.
"""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sessions = set()
initialize_count = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body=None, headers=None, content_type="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if body is not None:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_DELETE(self):
        sessions.discard(self.headers.get("Mcp-Session-Id"))
        self.reply(200)

    def do_POST(self):
        global initialize_count
        if self.path.rstrip("/") != "/mcp":
            return self.reply(404, {"error": "not found"})
        if self.headers.get("Authorization") != "Bearer test-key":
            return self.reply(401, {"error": "unauthorized"})
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method, id, params = msg.get("method"), msg.get("id"), msg.get("params", {})

        if method == "initialize":
            initialize_count += 1
            session = str(uuid.uuid4())
            sessions.add(session)
            return self.reply(200, {"jsonrpc": "2.0", "id": id, "result": {
                "protocolVersion": params.get("protocolVersion"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake-http", "version": "1"},
            }}, {"Mcp-Session-Id": session})

        if self.headers.get("Mcp-Session-Id") not in sessions:
            return self.reply(404, {"error": "unknown session"})
        if id is None:
            return self.reply(202)

        if method == "tools/list":
            return self.reply(200, {"jsonrpc": "2.0", "id": id, "result": {"tools": [
                {"name": "search", "inputSchema": {"type": "object"}},
            ]}})
        if method == "tools/call":
            name = params.get("name")
            if name == "restart":
                sessions.clear()
                text = "restarted"
            elif name == "stats":
                text = json.dumps({"initialize_count": initialize_count})
            else:
                text = json.dumps({"args": params.get("arguments"), "protocol": self.headers.get("MCP-Protocol-Version")})
            result = {"jsonrpc": "2.0", "id": id, "result": {"content": [{"type": "text", "text": text}]}}
            if "text/event-stream" not in self.headers.get("Accept", ""):
                return self.reply(200, result)
            events = ""
            token = params.get("_meta", {}).get("progressToken")
            if token is not None:
                progress = {"jsonrpc": "2.0", "method": "notifications/progress",
                            "params": {"progressToken": token, "progress": 1, "total": 1}}
                events += f"event: message\ndata: {json.dumps(progress)}\n\n"
            events += f"event: message\ndata: {json.dumps(result)}\n\n"
            return self.reply(200, events.encode(), content_type="text/event-stream")
        return self.reply(200, {"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "unknown"}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
