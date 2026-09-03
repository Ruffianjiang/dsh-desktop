#!/usr/bin/env python3
"""Generate placeholder app icons (PNG / ICO / ICNS) for the Tauri build.

Pure stdlib (zlib + struct) — no Pillow required. Produces a solid blue
rounded-less square so `tauri build` has valid icon assets. Replace these with
proper branded icons before shipping.
"""
import os
import struct
import zlib

ICONS_DIR = "src-tauri/icons"
RGBA = (43, 108, 255, 255)  # DeepSeek-ish blue


def make_png(path: str, size: int, rgba: tuple) -> bytes:
    raw = bytearray()
    row = bytes(rgba) * size
    for _ in range(size):
        raw.append(0)  # PNG filter type 0 (None)
        raw.extend(row)
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(typ: bytes, data: bytes) -> bytes:
        c = typ + data
        return (
            struct.pack(">I", len(data))
            + c
            + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
        )

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b"")


def make_ico(path: str, png_bytes: bytes) -> None:
    # ICO container wrapping a single PNG image.
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack(
        "<BBBBHHII",
        128,
        128,
        0,
        0,
        1,
        32,
        len(png_bytes),
        6 + 16,
    )
    with open(path, "wb") as f:
        f.write(header + entry + png_bytes)


def make_icns(path: str, png_bytes: bytes) -> None:
    # ICNS with a single ic07 (PNG) image.
    body = b"ic07" + struct.pack(">I", len(png_bytes)) + png_bytes
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main() -> None:
    os.makedirs(ICONS_DIR, exist_ok=True)
    png32 = make_png(os.path.join(ICONS_DIR, "32x32.png"), 32, RGBA)
    with open(os.path.join(ICONS_DIR, "32x32.png"), "wb") as f:
        f.write(png32)
    png128 = make_png(os.path.join(ICONS_DIR, "128x128.png"), 128, RGBA)
    with open(os.path.join(ICONS_DIR, "128x128.png"), "wb") as f:
        f.write(png128)
    with open(os.path.join(ICONS_DIR, "icon.png"), "wb") as f:
        f.write(png128)
    make_ico(os.path.join(ICONS_DIR, "icon.ico"), png32)
    make_icns(os.path.join(ICONS_DIR, "icon.icns"), png128)
    print("icons generated under", ICONS_DIR)


if __name__ == "__main__":
    main()
