SDK := $(shell xcrun --show-sdk-path)
SSDB := ../VisualizerApp/Sources/SSDBridge
TSG := ../VisualizerApp/Sources/TestSignalDSP
check: selfcheck fake_meter ssdcheck tsgcheck watchcheck
	cd $(CURDIR) && ./selfcheck && ./ssdcheck && ./tsgcheck && ./watchcheck
selfcheck: selfcheck.cpp $(SSDB)/ssd_bridge.cpp $(SSDB)/ssd_reader.h ../VisualizerApp/Sources/AudioBridge/audio_bridge.c
	clang++ -std=c++17 -O1 -I$(SSDB)/include -I../VisualizerApp/Sources/AudioBridge/include -o $@ $(filter-out %.h,$^)
ssdcheck: ssdcheck.cpp $(SSDB)/ssd_bridge.cpp $(SSDB)/ssd_reader.h $(SSDB)/include/ssd_bridge.h
	clang++ -std=c++17 -O1 -Wall -I$(SSDB)/include -o $@ ssdcheck.cpp $(SSDB)/ssd_bridge.cpp
tsgcheck: tsgcheck.c $(TSG)/test_signal.c $(TSG)/include/test_signal.h
	clang -O1 -Wall -I$(TSG)/include -o $@ tsgcheck.c $(TSG)/test_signal.c
fake_meter: fake_meter.c
	clang -o $@ $<
clean:
	rm -f selfcheck fake_meter ssdcheck tsgcheck watchcheck

harness: halharness.cpp ../HALPlugin/src/VirtualAudioDevicePlugin.cpp
	clang++ -std=c++17 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all '-DVAI_SHM_NAME="/vai_harness"' \
		-framework CoreFoundation -framework CoreAudio -o halharness $^
	./halharness
watchcheck: watchcheck.swift ../VisualizerApp/Sources/VisualizerApp/FileWatcher.swift
	swiftc -swift-version 5 -parse-as-library -o $@ $^
