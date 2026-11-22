TOOLS_PATH := ../zx3d/.tools
PYTHON ?= python3
SJASMPLUS ?= $(TOOLS_PATH)/sjasmplus/sjasmplus
Z88DK ?= $(TOOLS_PATH)/z88dk
ZESARUX ?= $(TOOLS_PATH)/zesarux/zesarux

.PHONY: all run test
all:
	$(PYTHON) build.py --z88dk "$(Z88DK)" --assembler "$(SJASMPLUS)"

run: all
	"$(ZESARUX)" --noconfigfile --machine Pentagon --nowelcomemessage --enable-betadisk --enable-trd \
		--trd-file "$(CURDIR)/build/fzx-viewer.trd" --trd-write-protection

test: all
	$(PYTHON) verify.py --z88dk "$(Z88DK)" --emulator "$(ZESARUX)"
