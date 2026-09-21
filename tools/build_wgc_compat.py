"""构建指定版本的本地 WGC 兼容层；本脚本只生成候选文件，不修改安装目录。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

import pefile

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL_SHA256 = "d09a2f3f4c144be9c180509f5cd67d60f4b0b6fbb62e0f5a1ee131f4b653c512"
DLL_NAME = "codex-wgc-readback.dll"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) // boundary * boundary


def patch_helper(original: bytes) -> tuple[bytes, dict]:
    if digest(original) != ORIGINAL_SHA256:
        raise ValueError("原生程序版本不匹配；拒绝给其他版本应用补丁")
    pe = pefile.PE(data=original)
    if pe.FILE_HEADER.Machine != 0x8664:
        raise ValueError("仅支持已检查的 x64 程序")
    activation = [entry for descriptor in pe.DIRECTORY_ENTRY_IMPORT for entry in descriptor.imports if entry.name == b"RoGetActivationFactory"]
    if len(activation) != 1 or activation[0].address != 0x140176F28:
        raise ValueError("WinRT 导入位置不匹配")
    # 唯一导入跳板已经用 LLVM 反汇编确认；保留全部既有导入与访问控制代码。
    jump_rva = 0x1246A4
    jump_offset = pe.get_offset_from_rva(jump_rva)
    if original[jump_offset:jump_offset + 6] != bytes.fromhex("ff257e280500"):
        raise ValueError("WinRT 跳板字节不匹配")
    border_offset = 251911
    if original[border_offset:border_offset + 6] != bytes.fromhex("488364246000"):
        raise ValueError("可选边框设置字节不匹配")

    next_header = pe.sections[-1].get_file_offset() + 40
    if next_header + 40 > pe.sections[0].PointerToRawData:
        raise ValueError("PE 头部没有空间容纳兼容层导入节")
    section_rva = align(max(s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData) for s in pe.sections), pe.OPTIONAL_HEADER.SectionAlignment)
    section_raw = align(len(original), pe.OPTIONAL_HEADER.FileAlignment)
    old_descriptors = b"".join(entry.struct.__pack__() for entry in pe.DIRECTORY_ENTRY_IMPORT)
    payload = bytearray(old_descriptors + b"\0" * 40)

    def append(data: bytes, boundary: int = 1) -> int:
        payload.extend(b"\0" * (align(len(payload), boundary) - len(payload)))
        rva = section_rva + len(payload)
        payload.extend(data)
        return rva

    dll_name_rva = append(DLL_NAME.encode("ascii") + b"\0")
    function_rva = append(b"\0\0WgcRoGetActivationFactory\0", 2)
    lookup_rva = append(struct.pack("<QQ", function_rva, 0), 8)
    iat_rva = append(struct.pack("<QQ", function_rva, 0), 8)
    struct.pack_into("<IIIII", payload, len(old_descriptors), lookup_rva, 0, 0, dll_name_rva, iat_rva)
    virtual_size = len(payload)
    raw_size = align(virtual_size, pe.OPTIONAL_HEADER.FileAlignment)
    payload.extend(b"\0" * (raw_size - virtual_size))
    pe.FILE_HEADER.NumberOfSections += 1
    pe.OPTIONAL_HEADER.SizeOfImage = align(section_rva + virtual_size, pe.OPTIONAL_HEADER.SectionAlignment)
    pe.OPTIONAL_HEADER.SizeOfInitializedData += raw_size
    directory = pe.OPTIONAL_HEADER.DATA_DIRECTORY[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]]
    directory.VirtualAddress = section_rva
    directory.Size = len(old_descriptors) + 40
    result = bytearray(pe.write())
    result.extend(b"\0" * (section_raw - len(result)))
    result.extend(payload)
    struct.pack_into("<8sIIIIIIHHI", result, next_header, b".cuwgc\0\0", virtual_size, section_rva, raw_size, section_raw, 0, 0, 0, 0, 0xC0000040)
    struct.pack_into("<i", result, jump_offset + 2, iat_rva - (jump_rva + 6))
    result[border_offset:border_offset + 6] = bytes.fromhex("e99500000090")
    final = pefile.PE(data=bytes(result))
    struct.pack_into("<I", result, final.OPTIONAL_HEADER.get_field_absolute_offset("CheckSum"), final.generate_checksum())
    final = pefile.PE(data=bytes(result))
    imports = [entry.dll.decode("ascii") for entry in final.DIRECTORY_ENTRY_IMPORT]
    if imports != [entry.dll.decode("ascii") for entry in pe.DIRECTORY_ENTRY_IMPORT] + [DLL_NAME]:
        raise ValueError("候选文件的导入表验证失败")
    return bytes(result), {
        "original_sha256": ORIGINAL_SHA256,
        "patched_sha256": digest(result),
        "border_patch_file_offset": border_offset,
        "activation_jump_rva": jump_rva,
        "compatibility_iat_rva": iat_rva,
        "new_section_rva": section_rva,
        "signature_impact": "Original Authenticode hash no longer matches; no trust policy is changed",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--native-dir", type=Path, default=Path(os.environ["LOCALAPPDATA"]) / "OpenAI/Codex/runtimes/cua_node/df473e5367fa2b42/bin/node_modules/@oai/sky/bin/windows")
    source.add_argument("--original-exe", type=Path, help="从完整原版备份重新构建，不需要先回退已安装的修复")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts/build/wgc-readback-v2")
    args = parser.parse_args()
    original_path = args.original_exe or args.native_dir / "codex-computer-use.exe"
    original = original_path.read_bytes()
    patched, manifest = patch_helper(original)
    compiler = shutil.which("clang++")
    if not compiler:
        raise RuntimeError("需要本机已有的 LLVM-MinGW clang++ 编译器")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    dll = output / DLL_NAME
    command = [compiler, "-std=c++20", "-O2", "-shared", "-static", "-Wl,--no-insert-timestamp", str(ROOT / "tools/wgc_compat.cpp"), "-o", str(dll), "-ld3d11", "-ldxgi", "-lruntimeobject", "-lole32", "-luuid"]
    subprocess.run(command, check=True)
    (output / "codex-computer-use.compat.exe").write_bytes(patched)
    manifest.update({"dll_name": DLL_NAME, "dll_sha256": digest(dll.read_bytes()), "compiler": subprocess.check_output([compiler, "--version"], encoding="utf-8").splitlines()[0], "pefile_version": pefile.__version__})
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output_directory": str(output), **manifest}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
