"""Read-only desktop capture for Windows systems without WGC IsBorderRequired.

This tool captures visible desktop pixels; it does not replace the Computer Use
window API. Crop coordinates are physical pixels, with explicit image/screen
coordinate spaces. Requires Pillow, which is already installed on this machine.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sys


def crop_to_image(box, space, origin, size):
    """Convert and validate an exclusive-right/bottom crop without silent padding."""
    left, top, right, bottom = box
    if space == "screen":
        left, right = left - origin[0], right - origin[0]
        top, bottom = top - origin[1], bottom - origin[1]
    elif space != "image":
        raise ValueError("Coordinate space must be image or screen")
    if not (0 <= left < right <= size[0] and 0 <= top < bottom <= size[1]):
        raise ValueError(f"Crop {(left, top, right, bottom)} is outside image {size}")
    return left, top, right, bottom


def parse_box(value):
    try:
        parts = tuple(int(v.strip()) for v in value.split(","))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Crop must contain integer L,T,R,B") from error
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("Crop must contain exactly L,T,R,B")
    return parts


def desktop_geometry():
    if sys.platform != "win32":
        raise RuntimeError("This capture tool requires a Windows interactive desktop")
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
    user32.SetProcessDpiAwarenessContext.restype = wintypes.BOOL
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    user32.GetThreadDpiAwarenessContext.restype = ctypes.c_void_p
    user32.GetAwarenessFromDpiAwarenessContext.argtypes = [ctypes.c_void_p]
    user32.GetAwarenessFromDpiAwarenessContext.restype = ctypes.c_int
    if user32.GetAwarenessFromDpiAwarenessContext(user32.GetThreadDpiAwarenessContext()) != 2:
        raise RuntimeError("Per-monitor DPI awareness is required for reliable pixel coordinates")

    user32.OpenInputDesktop.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    user32.OpenInputDesktop.restype = wintypes.HANDLE
    user32.CloseDesktop.argtypes = [wintypes.HANDLE]
    user32.CloseDesktop.restype = wintypes.BOOL
    user32.GetUserObjectInformationW.argtypes = [
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
    ]
    user32.GetUserObjectInformationW.restype = wintypes.BOOL
    desktop = user32.OpenInputDesktop(0, False, 1)
    if not desktop:
        raise RuntimeError("Cannot access the active desktop; unlock Windows and retry")
    try:
        name = ctypes.create_unicode_buffer(256)
        needed = wintypes.DWORD()
        if not user32.GetUserObjectInformationW(desktop, 2, name, ctypes.sizeof(name), ctypes.byref(needed)):
            raise ctypes.WinError(ctypes.get_last_error())
        if name.value.casefold() != "default":
            raise RuntimeError("The active desktop is not the normal unlocked desktop")
    finally:
        user32.CloseDesktop(desktop)

    class MonitorInfo(ctypes.Structure):
        _fields_ = [
            ("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
            ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD),
            ("szDevice", wintypes.WCHAR * 32),
        ]

    callback_type = ctypes.WINFUNCTYPE(
        wintypes.BOOL, wintypes.HANDLE, wintypes.HDC,
        ctypes.POINTER(wintypes.RECT), wintypes.LPARAM,
    )
    user32.GetMonitorInfoW.argtypes = [wintypes.HANDLE, ctypes.POINTER(MonitorInfo)]
    user32.GetMonitorInfoW.restype = wintypes.BOOL
    user32.EnumDisplayMonitors.argtypes = [wintypes.HDC, ctypes.c_void_p, callback_type, wintypes.LPARAM]
    user32.EnumDisplayMonitors.restype = wintypes.BOOL
    monitors = []
    errors = []

    @callback_type
    def collect(handle, _hdc, _rect, _data):
        info = MonitorInfo()
        info.cbSize = ctypes.sizeof(info)
        if not user32.GetMonitorInfoW(handle, ctypes.byref(info)):
            errors.append(ctypes.get_last_error())
            return False
        rect = info.rcMonitor
        monitors.append({
            "id": len(monitors) + 1,
            "device": info.szDevice,
            "primary": bool(info.dwFlags & 1),
            "screen_rect": [rect.left, rect.top, rect.right, rect.bottom],
            "size": [rect.right - rect.left, rect.bottom - rect.top],
        })
        return True

    if not user32.EnumDisplayMonitors(None, None, collect, 0) or errors:
        raise RuntimeError(f"Cannot enumerate displays: {errors or ctypes.get_last_error()}")
    origin = [user32.GetSystemMetrics(76), user32.GetSystemMetrics(77)]
    size = [user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)]
    if not monitors or min(size) <= 0:
        raise RuntimeError("No active display was detected")
    for monitor in monitors:
        monitor["image_rect"] = list(crop_to_image(monitor["screen_rect"], "screen", origin, size))
    return {"origin": origin, "size": size, "monitors": monitors}


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--full", action="store_true", help="Capture the whole virtual desktop (default)")
    target.add_argument("--monitor", type=int, help="Monitor id from --list-monitors")
    target.add_argument("--crop", type=parse_box, help="Physical pixels L,T,R,B, right/bottom exclusive")
    parser.add_argument("--crop-space", choices=("image", "screen"), default="image")
    parser.add_argument("--list-monitors", action="store_true", help="Print geometry without capturing")
    parser.add_argument("--output", type=Path, help="New PNG path; existing images are never overwritten")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        geometry = desktop_geometry()
        if args.list_monitors:
            print(json.dumps(geometry, ensure_ascii=False, indent=2))
            return 0

        size, origin = geometry["size"], geometry["origin"]
        box = (0, 0, *size)
        if args.monitor is not None:
            monitor = next((m for m in geometry["monitors"] if m["id"] == args.monitor), None)
            if monitor is None:
                raise ValueError("Unknown monitor id; run --list-monitors again")
            box = tuple(monitor["image_rect"])
        elif args.crop is not None:
            box = crop_to_image(args.crop, args.crop_space, origin, size)

        stamp = datetime.now().astimezone()
        output = args.output or Path(__file__).resolve().parents[1] / "artifacts" / "screenshots" / f"desktop-{stamp:%Y%m%d-%H%M%S-%f}.png"
        output = output.resolve()
        if output.suffix.lower() != ".png":
            raise ValueError("Output must have a .png extension")
        metadata_path = output.with_suffix(".json")
        if output.exists() or metadata_path.exists():
            raise FileExistsError(f"Output already exists: {output} or {metadata_path}")

        # Import after configuring DPI awareness; never inject input or move windows.
        import PIL
        from PIL import ImageGrab

        with ImageGrab.grab(all_screens=True, include_layered_windows=True) as full:
            if full.size != tuple(size):
                raise RuntimeError(f"Display size changed: capture={full.size}, expected={size}; retry")
            if desktop_geometry() != geometry:
                raise RuntimeError("Display layout changed during capture; retry")
            with full.crop(box) as image:
                extrema = image.getextrema()
                if all(low == high for low, high in extrema):
                    raise RuntimeError("Capture is a uniform image; check desktop visibility before retrying")
                metadata = {
                    "captured_at": stamp.isoformat(),
                    "backend": "Pillow.ImageGrab/Windows GDI",
                    "pillow_version": PIL.__version__,
                    "native_computer_use_repaired": False,
                    "virtual_desktop": geometry,
                    "crop_image_rect": list(box),
                    "crop_screen_rect": [box[0] + origin[0], box[1] + origin[1], box[2] + origin[0], box[3] + origin[1]],
                    "output_size": list(image.size),
                    "channel_extrema": extrema,
                    "warning": "Visible pixels only: occlusion, minimization and protected content affect results.",
                }
                output.parent.mkdir(parents=True, exist_ok=True)
                with output.open("xb") as file:
                    image.save(file, format="PNG")
        metadata["sha256"] = hashlib.sha256(output.read_bytes()).hexdigest()
        with metadata_path.open("x", encoding="utf-8", newline="\n") as file:
            json.dump(metadata, file, ensure_ascii=False, indent=2)
            file.write("\n")
        print(json.dumps({"image": str(output), "metadata": str(metadata_path), **metadata}, ensure_ascii=False, indent=2))
        return 0
    except (OSError, RuntimeError, ValueError, ImportError) as error:
        print(f"Capture failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
