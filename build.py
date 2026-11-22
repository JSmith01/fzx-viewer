#!/usr/bin/env python3
"""Build a TR-DOS viewer from the original z88dk FZX font assets."""

import argparse
import json
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
FONT_PATH = "libsrc/font/fzx/fonts"
SECTOR_SIZE = 256
SECTORS_PER_TRACK = 16
GLYPH_TOP = 72
GLYPH_BOTTOM = 192
GLYPH_LEFT = 84
GLYPH_RIGHT = 252


def glyphs(data):
    """Yield the width, leading and bitmap for every FZX character with ink."""
    end_table = 3 + 3 * (data[2] - 31)
    offsets = [
        pos + (int.from_bytes(data[pos:pos + 2], "little") & 0x3FFF)
        for pos in range(3, end_table + 1, 3)
    ]
    if len(data) < end_table + 2 or offsets[0] < end_table + 2 or offsets[-1] != len(data):
        raise ValueError("FZX table or terminal offset outside the file")
    for index, (start, end) in enumerate(zip(offsets, offsets[1:])):
        metrics = data[5 + index * 3]
        width, shift = (metrics & 15) + 1, metrics >> 4
        stride = (width + 7) // 8
        if end < start or (end - start) % stride:
            raise ValueError(f"Invalid FZX bitmap length for character {index + 32:02X}")
        bitmap = data[start:end]
        pad_mask = (1 << (-width % 8)) - 1
        if any(value & pad_mask for value in bitmap[stride - 1::stride]):
            raise ValueError(f"FZX bitmap exceeds the declared width at {index + 32:02X}")
        if any(bitmap):
            yield index + 32, width, shift, bitmap


def layout(characters):
    """Index the first and last non-empty character on each glyph row."""
    height = max(shift + len(bitmap) // ((width + 7) // 8)
                 for _, width, shift, bitmap in characters)
    pitch = height + 7  # One pixel above and below the five-pixel code label.
    if GLYPH_TOP + pitch > GLYPH_BOTTOM:
        raise ValueError("Glyph and code label do not fit on screen")

    x = GLYPH_LEFT
    rows = []
    first = last = characters[0][0]
    for code, width, _, _ in characters:
        advance = max(7, width) + 2
        if x + advance > GLYPH_RIGHT:
            rows.append([first, last])
            first = code
            x = GLYPH_LEFT
        x += advance
        last = code
    rows.append([first, last])
    return pitch, rows


def compress(z88dk, path, workspace):
    streams = {}
    for codec in ("zx0", "zx7"):
        target = workspace / codec
        subprocess.run([z88dk / "bin" / f"z88dk-{codec}", "-f", path, target],
                       stdout=subprocess.DEVNULL, check=True)
        streams[codec] = target.read_bytes()
    return streams


def asm_string(value):
    return "    db " + ",".join(str(code) for code in value.encode("ascii") + b"\0")


def z88dk_version(z88dk):
    """Read the installed tools' version stamp without consulting the parent repository."""
    assembler = z88dk / "bin/z88dk-z80asm"
    if assembler.is_file():
        output = subprocess.run([assembler, "-h"], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")
        match = re.search(r"^Z80 Macro Assembler\s+(\S+)", output.stdout, re.MULTILINE)
        if match:
            return "v" + match[1].removeprefix("v")

    config = z88dk / "src/config.h"
    if config.is_file():
        match = re.search(r'^#define Z88DK_VERSION "([^"]+)"', config.read_text(), re.MULTILINE)
        if match:
            return "v" + match[1].removeprefix("v")

    if (z88dk / ".git").exists():
        result = subprocess.run(["git", "-C", z88dk, "describe", "--always", "--dirty"],
                                capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    return "version unavailable"


def make_catalog(z88dk, workspace):
    base = z88dk / FONT_PATH
    sources = sorted(base.rglob("*.fzx"), key=lambda path: (str(path).casefold(), str(path)))
    if not sources:
        raise ValueError(f"No .fzx files found in {base}")
    collections = sorted({path.relative_to(base).parts[0] for path in sources})
    if not all(1 <= len(name) <= 8 and "." not in name for name in collections):
        raise ValueError("TR-DOS collection names must be 1–8 characters without a dot")
    if len(collections) > 14:
        raise ValueError("Collection entries exceed the first TR-DOS directory sector")

    packs = {codec: {name: bytearray() for name in collections} for codec in ("zx0", "zx7")}
    nodes = {Path("."): 0}
    children = {Path("."): []}
    font_entries = []
    for source in sources:
        path = source.relative_to(base)
        raw = source.read_bytes()
        try:
            characters = list(glyphs(raw))
            pitch, rows = layout(characters)
        except (IndexError, ValueError) as error:
            raise ValueError(f"{path}: {error}") from error
        for entry in (*reversed(path.parents), path):
            if entry in nodes:
                continue
            nodes[entry] = len(nodes)
            children[entry.parent].append(entry)
            if entry != path:
                children[entry] = []

        collection = path.parts[0]
        streams = compress(z88dk, source, workspace)
        sizes = {}
        for codec, stream in streams.items():
            pack = packs[codec][collection]
            sizes[codec] = {"offset": len(pack), "size": len(stream)}
            pack.extend(stream)
        font_entries.append({
            "path": path.as_posix(), "node": nodes[path], "raw_bytes": len(raw),
            "slot": collections.index(collection) + 2, "pitch": pitch,
            "rows": rows, "glyphs": len(characters), "compressed": sizes,
        })

    def sectors(codec):
        return sum((len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE
                   for data in packs[codec].values())

    totals = {codec: sum(map(len, group.values())) for codec, group in packs.items()}
    codec = min(packs, key=lambda name: (sectors(name), totals[name]))
    # The ZX0 decoder is used by the viewer. Fail explicitly if the source
    # collection changes enough to favor a different codec.
    if codec != "zx0":
        raise ValueError(f"This font set favors {codec}; the viewer currently decodes ZX0")

    by_path = {Path(font["path"]): font for font in font_entries}
    default = by_path.get(Path("ao/Sinclair/Sinclair.fzx"), font_entries[0])
    catalog = [
        "; Generated from z88dk, do not edit.",
        f"    ASSERT FONT_BUFFER + {max(font['raw_bytes'] for font in font_entries)} <= DIRECTORY",
        f"catalog_root EQU node_{nodes[Path('.')]}",
        f"catalog_default EQU node_{default['node']}",
    ]
    for path, index in nodes.items():
        is_dir = path in children
        parent = f"node_{nodes[path.parent]}" if path != Path(".") else "0"
        catalog += [f"node_{index}:", f"    dw {parent},name_{index},data_{index}"]
        if is_dir:
            entries = children[path]
            if len(entries) > 255:
                raise ValueError(f"{path}: more than 255 directory entries")
            catalog += [f"    db {len(entries)},0"]
            name = path.name + "/" if index else "fonts/"
            if index and len(path.as_posix()) + 1 > 19:
                raise ValueError(f"Directory path too long for the sidebar: {path}")
            catalog += [f"data_{index}:"]
            catalog += [f"    dw node_{nodes[child]}" for child in entries]
        else:
            font = by_path[path]
            offset = font["compressed"][codec]["offset"]
            length = font["compressed"][codec]["size"]
            relative_sector, skip = divmod(offset, SECTOR_SIZE)
            track, sector = divmod(relative_sector, SECTORS_PER_TRACK)
            count = (skip + length + SECTOR_SIZE - 1) // SECTOR_SIZE
            name = path.name
            if len(path.as_posix()) > 43:
                raise ValueError(f"Font path too long for the heading: {path}")
            catalog += [
                "    db 0", f"data_{index}:",
                f"    db {font['slot'] * 16},{sector},{track},{count},{skip}",
                f"    db {font['pitch']},{len(font['rows'])},{font['glyphs']}",
                f"    ASSERT INPUT_BUFFER + {count * SECTOR_SIZE} <= STACK_BOTTOM",
            ]
            catalog += [f"    db {first},{last}" for first, last in font["rows"]]
        catalog += [f"name_{index}:", asm_string(name)]
    (BUILD / "catalog.inc").write_text("\n".join(catalog) + "\n")

    disk_packs = []
    for name, pack in packs[codec].items():
        if len(pack) > 0xC000:
            raise ValueError(f"{name}: font collection exceeds the TR-DOS pack assembly buffer")
        (BUILD / f"{name}.pack").write_bytes(pack)
        disk_packs += [
            "    ORG $4000",
            f'    INCBIN "{name}.pack"',
            f'    SAVETRD "fzx-viewer.trd","{name}.C",$4000,$-$4000',
        ]
    (BUILD / "packs.inc").write_text("\n".join(disk_packs) + "\n")
    return {
        "codec": codec,
        "compressed_bytes": totals,
        "font_sectors": {name: sectors(name) for name in packs},
        "codec_wins": {
            name: sum(font["compressed"][name]["size"]
                      < font["compressed"][other]["size"] for font in font_entries)
            for name, other in (("zx0", "zx7"), ("zx7", "zx0"))
        },
        "fonts": font_entries,
    }


def disk_entries(image):
    """Return a mapping from TR-DOS catalog slot to name, sector and length."""
    if len(image) != 80 * 2 * SECTORS_PER_TRACK * SECTOR_SIZE or image[0x8E7] != 0x10:
        raise ValueError("Invalid double-sided TR-DOS image")
    entries = {}
    for slot in range(128):
        pos = slot * 16
        if image[pos] == 0:
            break
        name = image[pos:pos + 9]
        length = int.from_bytes(image[pos + 11:pos + 13], "little")
        sectors, sector, track = image[pos + 13:pos + 16]
        start = (track * SECTORS_PER_TRACK + sector) * SECTOR_SIZE
        if length > sectors * SECTOR_SIZE or start + sectors * SECTOR_SIZE > len(image):
            raise ValueError(f"Invalid TR-DOS file record {slot}")
        entries[slot] = name, start, length
    return entries


def verify_packs(z88dk, work, manifest):
    codec = manifest["codec"]
    image = (BUILD / "fzx-viewer.trd").read_bytes()
    entries = disk_entries(image)
    stream, output = work / "stream", work / "decoded"
    for font in manifest["fonts"]:
        path = Path(font["path"])
        name, base, length = entries[font["slot"]]
        record = font["compressed"][codec]
        start, size = record["offset"], record["size"]
        if name != path.parts[0].encode("ascii").ljust(8) + b"C" or start + size > length:
            raise ValueError(f"Invalid disk position for {path}")
        stream.write_bytes(image[base + start:base + start + size])
        subprocess.run([z88dk / "bin" / f"z88dk-d{codec}", "-f", stream, output],
                       stdout=subprocess.DEVNULL, check=True)
        if output.read_bytes() != (z88dk / FONT_PATH / path).read_bytes():
            raise ValueError(f"TR-DOS round-trip mismatch for {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--z88dk", type=Path, required=True)
    parser.add_argument("--assembler", type=Path, required=True)
    args = parser.parse_args()
    z88dk = args.z88dk.resolve()
    assembler = args.assembler.resolve()
    BUILD.mkdir(exist_ok=True)
    with TemporaryDirectory(dir=BUILD) as temporary:
        work = Path(temporary)
        manifest = make_catalog(z88dk, work)
        version = z88dk_version(z88dk)
        manifest["z88dk_version"] = version
        (BUILD / "z88dk-version.inc").write_text(asm_string(f"z88dk {version}") + "\n")
        ui_font = z88dk / "libsrc/font/font_4x8/font_4x8_64_owen.bin"
        (BUILD / "ui-font.bin").write_bytes(ui_font.read_bytes())
        decoder = z88dk / "libsrc/compress/zx0/z80"
        subprocess.run([assembler, f"--inc={decoder}", "--sym=viewer.sym",
                        ROOT / "viewer.asm"], cwd=BUILD, check=True)
        subprocess.run([assembler, ROOT / "disk.asm"], cwd=BUILD, check=True)
        verify_packs(z88dk, work, manifest)
    (BUILD / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified all {len(manifest['fonts'])} original fonts in the TR-DOS image.")
    for codec, size in manifest["compressed_bytes"].items():
        print(f"{codec.upper()}: {size:,} bytes, {manifest['font_sectors'][codec]} font sectors")
    print(BUILD / "fzx-viewer.trd")


if __name__ == "__main__":
    main()
