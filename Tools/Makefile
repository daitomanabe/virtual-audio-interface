SDK := $(shell xcrun --show-sdk-path)
check: selfcheck fake_meter
	cd $(CURDIR) && ./selfcheck
selfcheck: selfcheck.cpp ../VisualizerApp/Sources/SSDBridge/ssd_bridge.cpp ../VisualizerApp/Sources/AudioBridge/audio_bridge.c
	clang++ -std=c++17 -O1 -I../VisualizerApp/Sources/SSDBridge/include -I../VisualizerApp/Sources/AudioBridge/include -o $@ $^
fake_meter: fake_meter.c
	clang -o $@ $<
clean:
	rm -f selfcheck fake_meter
