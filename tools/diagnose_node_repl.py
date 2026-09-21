"""检查用户配置的 node_repl MCP 启动、JavaScript 与只读窗口枚举。"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    codex = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    config = tomllib.loads((codex / "config.toml").read_text(encoding="utf-8-sig"))
    server = config.get("mcp_servers", {}).get("node_repl")
    if not server or not server.get("command"):
        raise RuntimeError("配置中没有外部 node_repl；这不代表应用内置入口不可用")
    process = subprocess.Popen([server["command"], *server.get("args", [])], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, **server.get("env", {})}, cwd=ROOT, text=True, encoding="utf-8")
    messages: queue.Queue = queue.Queue()
    stderr_lines = []

    def read_stdout() -> None:
        for line in process.stdout:
            messages.put(line)

    def read_stderr() -> None:
        for line in process.stderr:
            stderr_lines.append(line)

    threading.Thread(target=read_stdout, daemon=True).start()
    threading.Thread(target=read_stderr, daemon=True).start()

    def send(value: dict) -> None:
        process.stdin.write(json.dumps(value) + "\n")
        process.stdin.flush()

    def request(identifier: int, method: str, params: dict) -> dict:
        send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            response = json.loads(messages.get(timeout=max(0.01, deadline - time.monotonic())))
            # 诊断客户端不代替用户批准应用访问，也不发起截图或输入动作。
            if response.get("method") == "elicitation/create":
                send({"jsonrpc": "2.0", "id": response["id"], "result": {"action": "cancel"}})
            elif response.get("id") == identifier:
                return response
        raise TimeoutError("MCP response timed out")

    report = {"configured_executable_exists": Path(server["command"]).is_file(), "configuration_modified": False}
    try:
        initialized = request(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "computer-use-local-diagnostic", "version": "1"}})
        report["initialize_ok"] = "result" in initialized
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        listing = request(2, "tools/list", {})
        report["tool_names"] = [tool["name"] for tool in listing.get("result", {}).get("tools", [])]
        for identifier, label, code in [
            (3, "javascript", 'nodeRepl.write(JSON.stringify({javascript: "ok", skyRpcAvailable: typeof nodeRepl.rpc === "function"}));'),
            (4, "window_enumeration", 'globalThis.sky = (await import("@oai/sky")).sky; globalThis.windows = await sky.list_windows(); nodeRepl.write(JSON.stringify({windowCount: windows.length}));'),
        ]:
            result = request(identifier, "tools/call", {"name": "js", "arguments": {"code": code, "title": "只读诊断 Computer Use 工具入口", "timeout_ms": 10000}})
            body = result.get("result", {})
            report[label] = {"ok": "error" not in result and not body.get("isError", False), "text": [part["text"] for part in body.get("content", []) if part.get("type") == "text"]}
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)
        report["stderr_line_count"] = len(stderr_lines)
    output = ROOT / "artifacts/diagnostics/node-repl-status.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("javascript", {}).get("ok") and report.get("window_enumeration", {}).get("ok") else 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
