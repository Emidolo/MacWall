# Builds with Xcode or just the Command Line Tools.
ARCHS ?= $(shell uname -m)
CONFIG ?= release
APP = build/MacWall.app
# One build per architecture, merged with lipo (multi-arch `swift build` needs Xcode's XCBuild).
BINS = $(foreach a,$(ARCHS),.build/$(a)-apple-macosx/$(CONFIG)/MacWall)
# Swift Testing ships outside the default search path when only the CLT are installed.
CLT_FW = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS = $(if $(wildcard $(CLT_FW)/Testing.framework),-Xswiftc -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_LIB))

.PHONY: build test app run clean

build:
	for a in $(ARCHS); do swift build -c $(CONFIG) --arch $$a || exit 1; done

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	lipo -create $(BINS) -output $(APP)/Contents/MacOS/MacWall
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --timestamp=none $(APP)

run: app
	open $(APP)

clean:
	rm -rf .build build
