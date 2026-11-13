#!/usr/bin/env python3
"""A tiny language server used by the test suite. It reports back what it was
told (so tests can check URI translation) and answers a few requests."""
import json, os, sys
from urllib.parse import unquote

def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        k, _, v = line.partition(b":")
        if k.lower() == b"content-length":
            length = int(v)
    return json.loads(sys.stdin.buffer.read(length))

def send(msg):
    body = json.dumps(msg).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()

init = {}
while True:
    m = read()
    if m is None:
        break
    method = m.get("method")
    if method == "initialize":
        init = m["params"]
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {
            "textDocumentSync": 1, "definitionProvider": True, "documentSymbolProvider": True}}})
    elif method == "textDocument/didOpen":
        uri = m["params"]["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": [{
            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
            "severity": 2,
            "message": "opened %s cwd=%s rootUri=%s pid=%s exists=%s" % (
                uri, os.getcwd(), init.get("rootUri"), init.get("processId"), os.path.exists(unquote(uri[len("file://"):])))}]}})
    elif method == "textDocument/definition":
        uri = m["params"]["textDocument"]["uri"]
        other = uri.rsplit("/", 1)[0] + "/other%20file.txt"
        send({"jsonrpc": "2.0", "id": m["id"], "result": [{"uri": other,
            "range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 5}}}]})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
    elif method == "exit":
        break
    elif "id" in m and method:
        send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "not implemented"}})
