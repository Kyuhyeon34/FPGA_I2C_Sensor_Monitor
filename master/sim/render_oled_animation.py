"""Render captured SSD1306 GDDRAM into an animated GIF; standard library only."""
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parent / "build"
SCALE = 6
WIDTH, HEIGHT = 128 * SCALE, 32 * SCALE


def pixels(path):
    data = [int(line.strip(), 16) for line in path.read_text().splitlines()
            if re.fullmatch(r"[0-9a-fA-F]{2}", line.strip())]
    if len(data) != 512:
        raise ValueError(f"Expected 512 GDDRAM bytes: {path}")
    for y in range(HEIGHT):
        row = y // SCALE
        for x in range(WIDTH):
            yield (data[(row // 8) * 128 + x // SCALE] >> (row % 8)) & 1


def gif_data(path):
    # Reset before every pixel: tiny fixed 3-bit codes, no dictionary or Pillow.
    output = bytearray()
    pending = count = 0
    def push(code):
        nonlocal pending, count
        pending |= code << count
        count += 3
        while count >= 8:
            output.append(pending & 255)
            pending >>= 8
            count -= 8
    for value in pixels(path):
        push(4)
        push(value)
    push(5)
    if count:
        output.append(pending & 255)
    blocks = bytearray(b"\x02")
    for start in range(0, len(output), 255):
        block = output[start:start + 255]
        blocks.append(len(block))
        blocks.extend(block)
    blocks.append(0)
    return blocks


result = bytearray(b"GIF89a" + struct.pack("<HHBBB", WIDTH, HEIGHT, 0x80, 0, 0))
result.extend(bytes([5, 12, 16, 110, 220, 255]))
result.extend(b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00")
for index in range(4):
    result.extend(b"\x21\xf9\x04\x04" + struct.pack("<H", 54) + b"\x00\x00")
    result.extend(b"\x2c" + struct.pack("<HHHHB", 0, 0, WIDTH, HEIGHT, 0))
    result.extend(gif_data(ROOT / f"oled_animation_{index}.hex"))
result.append(0x3B)
destination = ROOT / "slowpoke_oled_preview.gif"
destination.write_bytes(result)
print(destination)
