# Minimal build for the HAL plugin bundle. Uses the newest installed macOS SDK
# directly (xcode-select on this machine points at Command Line Tools, which
# doesn't ship CoreAudio/AudioServerPlugIn.h — the full Xcode.app SDK does).
SDK := $(shell find /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -iname 'MacOSX*.sdk' 2>/dev/null | sort -V | tail -1)
BUNDLE := build/VirtualAudioInterfaceDriver.driver
CXX := clang++
# Universal by default (arm64 + x86_64). Override with `make ARCHS="-arch arm64"`
# for a single-arch build if the toolchain can't link one of the slices.
ARCHS ?= -arch arm64 -arch x86_64
CXXFLAGS := -std=c++17 -Wall -Wextra -fPIC $(ARCHS) -isysroot $(SDK) -mmacosx-version-min=13.0
FRAMEWORKS := -framework CoreFoundation -framework CoreAudio -bundle

.PHONY: all clean check-sdk

all: $(BUNDLE)/Contents/MacOS/VirtualAudioInterfaceDriver

check-sdk:
	@if [ -z "$(SDK)" ]; then echo "No macOS SDK with CoreAudio/AudioServerPlugIn.h found"; exit 1; fi
	@echo "Using SDK: $(SDK)"

$(BUNDLE)/Contents/MacOS/VirtualAudioInterfaceDriver: src/VirtualAudioDevicePlugin.cpp ../Shared/MeterShm.h | check-sdk
	@mkdir -p $(BUNDLE)/Contents/MacOS
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -o $@ src/VirtualAudioDevicePlugin.cpp
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	# Source hash lets the app tell whether an installed driver is different code.
	plutil -replace VAIDriverSourceHash -string $$(cat src/*.cpp ../Shared/MeterShm.h Info.plist Makefile | shasum -a 256 | cut -c1-16) $(BUNDLE)/Contents/Info.plist

clean:
	rm -rf build
