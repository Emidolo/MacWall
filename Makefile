# Builds with Xcode or just the Command Line Tools.
ARCHS ?= $(shell uname -m)
CONFIG ?= release
APP = build/MacWall.app
ARCH_FLAGS = $(foreach a,$(ARCHS),--arch $(a))
# Swift Testing ships outside the default search path when only the CLT are installed.
CLT_FW = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS = $(if $(wildcard $(CLT_FW)/Testing.framework),-Xswiftc -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_LIB))

.PHONY: build test app run clean

build:
	swift build -c $(CONFIG) $(ARCH_FLAGS)

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) $(ARCH_FLAGS) --show-bin-path)/MacWall" $(APP)/Contents/MacOS/MacWall
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --timestamp=none $(APP)

run: app
	open $(APP)

clean:
	rm -rf .build build
