SDK := $(shell xcrun --show-sdk-path)
SSDB := ../VisualizerApp/Sources/SSDBridge
check: selfcheck fake_meter ssdcheck
	cd $(CURDIR) && ./selfcheck && ./ssdcheck
selfcheck: selfcheck.cpp $(SSDB)/ssd_bridge.cpp ../VisualizerApp/Sources/AudioBridge/audio_bridge.c
	clang++ -std=c++17 -O1 -I$(SSDB)/include -I../VisualizerApp/Sources/AudioBridge/include -o $@ $^
ssdcheck: ssdcheck.cpp $(SSDB)/ssd_bridge.cpp $(SSDB)/include/ssd_bridge.h
	clang++ -std=c++17 -O1 -Wall -I$(SSDB)/include -o $@ ssdcheck.cpp $(SSDB)/ssd_bridge.cpp
fake_meter: fake_meter.c
	clang -o $@ $<
clean:
	rm -f selfcheck fake_meter ssdcheck

harness: halharness.cpp ../HALPlugin/src/VirtualAudioDevicePlugin.cpp
	clang++ -std=c++17 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all '-DVAI_SHM_NAME="/vai_harness"' \
		-framework CoreFoundation -framework CoreAudio -o halharness $^
	./halharness
