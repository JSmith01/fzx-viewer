# FZX Font Viewer

Mount `build/fzx-viewer.trd` in drive A of a Pentagon 128. Select **TR-DOS** and enter `RUN "boot"` at the `A>` prompt. The disk uses the standard 640 KiB, double-sided TR-DOS format. It contains all 190 fonts from the project's z88dk checkout, with 20,881 non-empty glyphs.

## Controls

**Enter** cycles focus between the selector, specimen editor, and glyph browser. The active pane has a blue heading. In the selector and glyph browser, **H** opens Help and **R** restores the default text. Any key closes Help. Help shows the installed z88dk build version and the link to the upstream font directory. The green **H for help** hint appears at the root while the bottom row is free and gives its row to a full root listing after the first key.

- **Selector** · **W/S** or **Up/Down** moves through the current folder. **D** or **Right** opens a folder. **A** or **Left** goes to its parent. Highlighting a font loads it immediately.
- **Editor** · Type to replace “The quick brown fox jumps over the lazy dog. 1234567890”. Continue typing to append. The editor wraps at the first character that exceeds the available width. **Caps Shift+0** (Backspace) erases the last character. **Caps Shift+Enter** inserts a line break. **Left** focuses the selector, **Right** focuses the glyph browser, and **Up/Down** are ignored. The viewer keeps the text when changing fonts and scrolls to the newest line. If a font supplies only one case of a letter, the editor displays that case.
- **Glyph browser** · **W/S** or **Up/Down** scrolls one row at a time. The heading shows the FZX line height (`LH`) in pixels, the glyph count, the current row, and the original file size in bytes (`SZ`). Every bitmap with ink has a two-digit hexadecimal character code, including extended codes through `FF` when the font defines them.

The selector follows the case, filenames, and nesting of `libsrc/font/fzx/fonts`. The top right shows the selected font's path relative to that directory. Within the selector's visible list, navigation updates the two cursor rows' marker and colors. When the selector or glyph browser scrolls, it moves the existing bitmap and draws the newly exposed row. The disk contains one packed file for each top-level collection.

## Build and verification

It needs python3, sjasmplus, zesarux, and z88dk to be compiled. `TOOLS_PATH` in the `Makefile` points to directory where these reside.

From the project root, run `make`. It uses the project's bootstrapped SjASMPlus and z88dk tools. Set `Z88DK` or `SJASMPLUS` to use a different installation. Run `make run` to mount the disk in ZEsarUX, or `make test` for the Pentagon emulator tests.

The build compares independent, optimal ZX0 and ZX7 streams for every original FZX file. With this checkout, ZX0 won on all 190 fonts, taking 157,369 bytes and 619 TR-DOS sectors. ZX7 took 171,082 bytes and 672 sectors. The viewer reads only the sectors for the selected font, then uses Einar Saukas and Urusergi's ZX0 standard Z80 decoder. The build checks each stream from the finished disk against the original FZX file. Compression statistics and per-font glyph ranges are in `build/manifest.json`. [ZX0](https://github.com/einar-saukas/ZX0)

The viewer renders the original FZX bitmaps and uses their kerning and tracking in the editor. The interface font comes from z88dk's `font_4x8_64_owen.bin`. [z88dk FZX format](https://github.com/z88dk/z88dk/tree/master/libsrc/font/fzx)
