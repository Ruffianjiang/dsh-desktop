#!/usr/bin/env python3
"""Generate icons for the Electron build (pure stdlib).

Outputs:
  electron/assets/icon.png  — 256x256 RGBA (tray / window icon)
  build/icon.ico            — ICO wrapping the 256px PNG (electron-builder)

Replace with branded icons before shipping.
"""
import os
import struct
import zlib

RGBA = (43, 108, 255, 255)  # DeepSeek-ish blue
SIZE = 256


def make_png(size: int, rgba: tuple) -> bytes:
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


def make_ico(path: str, png_bytes: bytes, size: int) -> None:
    # ICO container wrapping a single PNG image. Width/height byte 0 means 256.
    w = h = (0 if size >= 256 else size)
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(png_bytes), 6 + 16)
    with open(path, "wb") as f:
        f.write(header + entry + png_bytes)


def main() -> None:
    png = make_png(SIZE, RGBA)
    os.makedirs("electron/assets", exist_ok=True)
    os.makedirs("build", exist_ok=True)
    with open("electron/assets/icon.png", "wb") as f:
        f.write(png)
    make_ico("build/icon.ico", png, SIZE)
    print("icons generated: electron/assets/icon.png, build/icon.ico")


if __name__ == "__main__":
    main()
