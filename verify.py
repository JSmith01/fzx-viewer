#!/usr/bin/env python3
"""Exercise TR-DOS boot, typing and glyph rendering on a Pentagon in ZEsarUX."""

import argparse
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

from build import BUILD, FONT_PATH, GLYPH_BOTTOM, GLYPH_LEFT, GLYPH_RIGHT, GLYPH_TOP, glyphs

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from spectrum import ZRCP, bitmap_offset, save_png, symbol


DEFAULT = b"The quick brown fox jumps over the lazy dog. 1234567890"
FONT_URL = "https://github.com/z88dk/z88dk/tree/master/libsrc/font/fzx/fonts"
HINT_Y = 184
HINT_ATTRS = slice(6144 + 23 * 32, 6144 + 23 * 32 + 10)
HEX_PIXELS = (
    (7, 5, 5, 5, 7), (2, 6, 2, 2, 7), (7, 1, 7, 4, 7), (7, 1, 7, 1, 7),
    (5, 5, 7, 1, 1), (7, 4, 7, 1, 7), (7, 4, 7, 5, 7), (7, 1, 1, 1, 1),
    (7, 5, 7, 5, 7), (7, 5, 7, 1, 7), (7, 5, 7, 5, 5), (6, 5, 6, 5, 6),
    (7, 4, 4, 4, 7), (6, 5, 5, 5, 6), (7, 4, 7, 4, 7), (7, 4, 7, 4, 4),
)


class Viewer:
    def __init__(self, protocol):
        self.protocol = protocol
        self.symbols = BUILD / "viewer.sym"

    def memory(self, address, length=1):
        if isinstance(address, str):
            address = symbol(address, self.symbols)
        return bytes.fromhex(self.protocol.command(f"read-memory {address} {length}"))

    def write_memory(self, address, data):
        if isinstance(address, str):
            address = symbol(address, self.symbols)
        self.protocol.command(f"write-memory-raw {address} {data.hex()}")

    def raw_keys(self, *keys):
        for key in keys:
            self.protocol.command(f"send-keys-event {key} 1")
        time.sleep(0.11)
        for key in reversed(keys):
            self.protocol.command(f"send-keys-event {key} 0")
        time.sleep(0.11)

    def text(self, text):
        codes = " ".join(str(code) for code in text.encode("ascii"))
        self.protocol.command(f"send-keys-ascii 110 {codes}")

    def ready(self, wait_start="next_key", wait_end="scan_keys"):
        start = symbol(wait_start, self.symbols)
        end = symbol(wait_end, self.symbols)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            registers = self.protocol.command("get-registers")
            if start <= int(registers.split()[0][3:], 16) < end:
                return
            time.sleep(0.03)
        save_png(self.screen(), BUILD / "failure.png")
        raise AssertionError(f"Viewer did not reach input. Last CPU state {registers}")

    def screen(self):
        return self.memory(0x4000, 6912)

    def screen_pixel(self, x, y, value=None):
        address = 0x4000 + bitmap_offset(x, y)
        mask = 128 >> (x & 7)
        byte = self.memory(address)[0]
        if value is None:
            return bool(byte & mask)
        byte = (byte | mask) if value else (byte & ~mask)
        self.write_memory(address, bytes([byte]))

    def expect_font(self, source, font):
        expected_node = symbol(f"node_{font['node']}", self.symbols)
        actual_node = int.from_bytes(self.memory("current_font", 2), "little")
        assert actual_node == expected_node, (font["path"], hex(actual_node), hex(expected_node))
        assert self.memory("FONT_BUFFER", len(source)) == source, font["path"]

    def expect_text(self, text):
        assert self.memory("sample_length") == bytes([len(text)])
        assert self.memory("sample_text", len(text)) == text


def set_rows(expected, x, y, bitmap, stride):
    for row in range(len(bitmap) // stride):
        pixels = int.from_bytes(bitmap[row * stride:(row + 1) * stride], "big")
        for bit in range(stride * 8):
            if pixels & (1 << (stride * 8 - 1 - bit)):
                expected.add((x + bit, y + row))


def check_pixels(screen, expected, top, bottom, left=80, right=256):
    actual = {(x, y) for y in range(top, bottom) for x in range(left, right)
              if screen[bitmap_offset(x, y)] & (128 >> (x & 7))}
    assert actual == expected, (len(actual), len(expected),
                                sorted(actual ^ expected)[:12])


def check_glyphs(screen, source, font, first):
    characters = list(glyphs(source))
    pitch = font["pitch"]
    rows = font["rows"]
    expected = set()
    y = GLYPH_TOP
    count = (GLYPH_BOTTOM - GLYPH_TOP) // pitch
    for low, high in rows[first:first + count]:
        x = GLYPH_LEFT
        for code, width, shift, bitmap in characters:
            if not low <= code <= high:
                continue
            set_rows(expected, x, y + shift, bitmap, (width + 7) // 8)
            for column, digit in enumerate((code >> 4, code & 15)):
                bits = bytes(row << 5 for row in HEX_PIXELS[digit])
                set_rows(expected, x + column * 4, y + pitch - 6, bits, 1)
            x += max(7, width) + 2
        y += pitch
    check_pixels(screen, expected, GLYPH_TOP, GLYPH_BOTTOM)


def check_ui_text(screen, text, y, x=GLYPH_LEFT, left=80, right=256):
    font = (BUILD / "ui-font.bin").read_bytes()
    expected = set()
    for column, char in enumerate(text):
        start = (ord(char) - 32) * 8
        bitmap = bytes(byte & 0xF0 for byte in font[start:start + 8])
        set_rows(expected, x + column * 4, y, bitmap, 1)
    check_pixels(screen, expected, y, y + 8, left, right)


def check_help_hint(screen):
    assert screen[HINT_ATTRS] == b"\x60" * 10
    check_ui_text(screen, "H for help", HINT_Y, x=4, left=0, right=79)


def check_editor(screen, source, text, pitch, caret=True):
    height = max(source[0], pitch - 7) + 2
    all_glyphs = {code: (width, shift, bitmap)
                  for code, width, shift, bitmap in glyphs(source)}
    top, bottom = 8, 64
    x, y = GLYPH_LEFT, top
    expected = set()
    for code in text:
        if code == 10:
            x, y = GLYPH_LEFT, y + height
            continue
        entry = 3 + (code - 32) * 3
        width = (source[entry + 2] & 15) + 1
        kern = source[entry + 1] >> 6
        x = max(GLYPH_LEFT, x - kern)
        if x + width > GLYPH_RIGHT:
            x, y = GLYPH_LEFT, y + height
        if code in all_glyphs:
            _, shift, bitmap = all_glyphs[code]
            set_rows(expected, x, y + shift, bitmap, (width + 7) // 8)
        x = min(255, x + width + source[1])
    if caret:
        x = min(x, GLYPH_RIGHT - 3)
        expected.update((x + bit, y + height - 1) for bit in range(3))
    visible_height = (bottom - top) // height * height
    scroll = max(0, y + height - top - visible_height)
    expected = {(px, py - scroll) for px, py in expected if py - scroll >= top}
    check_pixels(screen, expected, top, bottom)


def verify(viewer, z88dk):
    manifest = json.loads((BUILD / "manifest.json").read_text())
    fonts = {font["path"]: font for font in manifest["fonts"]}

    def open_font(path):
        font = fonts[path]
        source = (z88dk / FONT_PATH / path).read_bytes()
        viewer.expect_font(source, font)
        check_ui_text(viewer.screen(),
                      f"LH {source[0]}  GLYPHS {font['glyphs']}  "
                      f"ROW 001/{len(font['rows']):03}  SZ {len(source)}", 64)
        return source, font

    def select(keys):
        for key in keys:
            viewer.text(key)
            viewer.ready()

    def help_screen(before, exit_key=ord("s")):
        viewer.text("h")
        viewer.ready("help_wait_press", "help_wait_release")
        screen = viewer.screen()
        assert screen[6144:] == b"\x4f" * 768
        title, prompt = "FZX FONT VIEWER HELP", "any key to return"
        check_ui_text(screen, title.ljust(61 - len(prompt)) + prompt, 8, x=12, left=0)
        check_ui_text(screen, "", 152, left=0)
        check_ui_text(screen, f"z88dk {manifest['z88dk_version']}", 160, x=12, left=0)
        check_ui_text(screen, "", 168, left=0)
        check_ui_text(screen, FONT_URL, 176, x=0, left=0)
        save_png(screen, BUILD / "help.png")
        viewer.raw_keys(exit_key)
        viewer.ready()
        assert viewer.screen() == before

    # Enter TR-DOS on the 128K menu and type RUN "boot" at the A> prompt.
    time.sleep(4)
    for _ in range(4):
        viewer.raw_keys(144)  # ZEsarUX cursor-down key
    viewer.raw_keys(129)      # Enter
    time.sleep(0.6)
    viewer.text('run "boot"')
    viewer.raw_keys(129)
    viewer.ready()

    source, font = open_font("ao/Sinclair/Sinclair.fzx")
    viewer.expect_text(DEFAULT)
    assert viewer.memory("focus") == b"\0"
    screen = viewer.screen()
    check_help_hint(screen)
    check_ui_text(screen, font["path"], 0)
    check_editor(screen, source, DEFAULT, font["pitch"], caret=False)
    check_glyphs(screen, source, font, 0)
    save_png(screen, BUILD / "viewer.png")
    help_screen(screen)
    select("q")
    assert viewer.screen() == screen

    # A selector move between folders only changes the two markers and their attributes.
    viewer.screen_pixel(76, 27, True)
    before = viewer.screen()
    select("s")
    after = viewer.screen()
    check_help_hint(after)
    cursor_bytes = {bitmap_offset(0, y) for y in range(8, 24)}
    cursor_attrs = {6144 + row * 32 + col for row in (1, 2) for col in range(10)}
    changes = {i for i, (a, b) in enumerate(zip(before, after)) if a != b}
    assert changes & cursor_bytes and changes & cursor_attrs
    assert changes <= cursor_bytes | cursor_attrs, sorted(changes - cursor_bytes - cursor_attrs)
    select("w")
    assert viewer.screen() == before
    viewer.screen_pixel(76, 27, False)

    viewer.raw_keys(129)
    viewer.ready()
    assert viewer.memory("focus") == b"\1"
    # Plain h/r and digits stay printable while editing. Cursor keys send Caps+5–8.
    select("hHrR5678")
    viewer.expect_text(b"hHrR5678")
    for key in (144, 145):  # Down, Up
        viewer.raw_keys(key)
        viewer.ready()
        assert viewer.memory("focus") == b"\1"
        viewer.expect_text(b"hHrR5678")
    for key in "hr":  # The former editor-only chords now produce their symbols.
        viewer.raw_keys(135, 136, ord(key))
        viewer.ready()
    viewer.expect_text(b"hHrR5678^<")

    viewer.raw_keys(142)  # Left from the editor goes to the selector.
    viewer.ready()
    assert viewer.memory("focus") == b"\0"
    viewer.expect_text(b"hHrR5678^<")
    help_screen(viewer.screen(), exit_key=135)
    select("r")
    viewer.expect_text(DEFAULT)
    check_editor(viewer.screen(), source, DEFAULT, font["pitch"], caret=False)
    viewer.raw_keys(129)
    viewer.ready()
    select("x")
    viewer.raw_keys(143)  # Right from the editor goes to the glyph browser.
    viewer.ready()
    assert viewer.memory("focus") == b"\2"
    viewer.expect_text(b"x")
    select("r")
    viewer.expect_text(DEFAULT)
    assert viewer.memory("focus") == b"\2"
    viewer.raw_keys(129)
    viewer.ready()
    viewer.raw_keys(129)
    viewer.ready()
    assert viewer.memory("focus") == b"\1"

    viewer.text("Fox!")
    viewer.ready()
    viewer.expect_text(b"Fox!")
    check_editor(viewer.screen(), source, b"Fox!", font["pitch"])
    viewer.raw_keys(140)  # Backspace sends CAPS SHIFT + 0.
    viewer.raw_keys(135, 129)  # CAPS SHIFT + Enter inserts a newline.
    viewer.text("Z")
    viewer.ready()
    viewer.expect_text(b"Fox\nZ")
    check_editor(viewer.screen(), source, b"Fox\nZ", font["pitch"])

    viewer.raw_keys(129)
    viewer.ready()
    assert viewer.memory("focus") == b"\2"
    # A spare pixel in the glyph margin must move with the existing bitmap in both directions.
    marker_y = GLYPH_TOP + 1
    viewer.screen_pixel(80, marker_y + font["pitch"], True)
    select("s")
    assert viewer.memory("first_row") == b"\1"
    assert viewer.screen_pixel(80, marker_y)
    assert not viewer.screen_pixel(80, marker_y + font["pitch"])
    select("w")
    assert viewer.memory("first_row") == b"\0"
    assert viewer.screen_pixel(80, marker_y + font["pitch"])
    assert not viewer.screen_pixel(80, marker_y)
    viewer.screen_pixel(80, marker_y + font["pitch"], False)
    check_glyphs(viewer.screen(), source, font, 0)
    select("s")
    check_glyphs(viewer.screen(), source, font, 1)
    before = viewer.screen()
    help_screen(before, exit_key=129)
    select("q")
    assert viewer.screen() == before
    viewer.raw_keys(129)
    viewer.ready()
    assert viewer.memory("focus") == b"\0"

    select("d")
    assert viewer.screen()[HINT_ATTRS] == b"\x78" * 10
    select("s" * 22)
    viewer.screen_pixel(76, 17, True)
    select("s")
    assert viewer.memory("menu_first") == b"\1"
    assert viewer.screen_pixel(76, 9)
    assert not viewer.screen_pixel(76, 17)
    select("w" * 23)
    assert viewer.memory("menu_first") == b"\0"
    assert viewer.screen_pixel(76, 17)
    assert not viewer.screen_pixel(76, 9)
    viewer.screen_pixel(76, 17, False)
    select("d")
    open_font("ao/Aribeth/Aribeth14.fzx")
    select("s")
    open_font("ao/Aribeth/Aribeth6.fzx")
    viewer.expect_text(b"Fox\nZ")
    select("a" + "s" * 8 + "ds")
    source, font = open_font("ao/Grotesk/Grotesk_Latin1.fzx")
    assert any(code >= 0x80 and width > 8 for code, width, _, _ in glyphs(source))
    check_ui_text(viewer.screen(), font["path"], 0)
    save_png(viewer.screen(), BUILD / "extended-glyphs.png")
    viewer.raw_keys(129)
    viewer.ready()
    viewer.raw_keys(129)
    viewer.ready()
    for row_number in range(len(font["rows"])):
        assert viewer.memory("first_row") == bytes([row_number])
        check_glyphs(viewer.screen(), source, font, row_number)
        if row_number + 1 < len(font["rows"]):
            viewer.text("s")
            viewer.ready()
    viewer.raw_keys(129)
    viewer.ready()
    select("aa" + "s" * 4 + "dd")
    capitals, caps_font = open_font("dkud4/Font01/font01.fzx")
    viewer.expect_text(b"Fox\nZ")
    viewer.raw_keys(129)
    viewer.ready()
    check_editor(viewer.screen(), capitals, b"FOX\nZ", caps_font["pitch"])

    viewer.raw_keys(142)
    viewer.ready()
    select("aa")
    check_help_hint(viewer.screen())

    # TR-DOS packs ordinarily impose a smaller root. Emulate an overflowing
    # root in RAM so the first-key transition is exercised too.
    root = symbol("catalog_root", viewer.symbols)
    node_data = symbol("NODE_DATA", viewer.symbols)
    node_count = symbol("NODE_COUNT", viewer.symbols)
    root_list = int.from_bytes(viewer.memory(root + node_data, 2), "little")
    scratch = symbol("INPUT_BUFFER", viewer.symbols)
    viewer.write_memory(scratch, viewer.memory(root_list, 2) * 24)
    viewer.write_memory(root + node_data, scratch.to_bytes(2, "little"))
    viewer.write_memory(root + node_count, b"\x18")
    viewer.write_memory("root_touched", b"\0")
    select("r")
    screen = viewer.screen()
    assert screen[HINT_ATTRS] == b"\x78" * 10
    check_ui_text(screen, "ao/", HINT_Y, x=8, left=0, right=79)

    print(f"Pentagon verified TR-DOS boot, help, reset, character wrapping, arrow navigation, bitmap "
          f"scrolling and all {font['glyphs']} glyphs of an extended 16-pixel-wide font.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--z88dk", required=True, type=Path)
    parser.add_argument("--emulator", required=True, type=Path)
    args = parser.parse_args()
    emulator = args.emulator.resolve()
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    command = [
        emulator, "--noconfigfile", "--machine", "Pentagon", "--vo", "null", "--ao", "null",
        "--nowelcomemessage", "--enable-betadisk", "--enable-trd", "--trd-write-protection",
        "--trd-file", BUILD / "fzx-viewer.trd", "--enable-remoteprotocol",
        "--remoteprotocol-port", str(port),
    ]
    with (BUILD / "emulator.log").open("w") as log:
        process = subprocess.Popen(command, cwd=emulator.parent, stdout=log,
                                   stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=0.25)
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise
                    time.sleep(0.05)
            with connection:
                verify(Viewer(ZRCP(connection)), args.z88dk.resolve())
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
