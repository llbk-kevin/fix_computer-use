"""构建并运行独立 WGC 对照测试；只输出统计数据，不保存桌面图像。"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window-title", help="额外测试一个已打开、未最小化的资源管理器窗口")
    args = parser.parse_args()
    compiler = shutil.which("clang++")
    if not compiler:
        raise RuntimeError("未找到 LLVM-MinGW clang++")
    output = ROOT / "artifacts/diagnostics/wgc-probe"
    output.mkdir(parents=True, exist_ok=True)
    executable = output / "wgc_probe.exe"
    subprocess.run([compiler, "-std=c++20", "-O2", "-static", str(ROOT / "tools/wgc_probe.cpp"), "-o", str(executable), "-ld3d11", "-ldxgi", "-lruntimeobject", "-lole32", "-luuid", "-lshell32"], check=True)
    library = ROOT / "artifacts/build/wgc-readback-v2/codex-wgc-readback.dll"
    if not library.is_file():
        raise RuntimeError("请先生成本项目兼容层候选文件，以便进行完整对照")
    shutil.copyfile(library, output / library.name)
    cases = [("frame", "primary", "hardware"), ("callback", "primary", "hardware"), ("worker", "primary", "hardware"), ("shim", "primary", "hardware"), ("shim", "left", "hardware"), ("shim", "primary", "warp")]
    if args.window_title:
        cases.append(("shim", "window", "hardware"))
    results = []
    for mode, target, driver in cases:
        command = [str(executable), mode, target, driver]
        if target == "window":
            command.append(args.window_title)
        try:
            run = subprocess.run(command, capture_output=True, encoding="utf-8", timeout=15)
            result = json.loads(run.stdout)
            result.update({"exit_code": run.returncode, "bitmap_metadata": run.stderr.strip()})
        except subprocess.TimeoutExpired:
            result = {"mode": mode, "target": target, "driver": driver, "success": False, "process_timeout": True}
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    (output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # callback 为故障对照，允许超时；其余正常路径应全部成功。
    return 0 if all(item.get("success") for item in results if item["mode"] != "callback") else 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
