import AppKit
import AudioToolbox
import CoreAudio
import TestSignalDSP

/// Plays a generated test signal into exactly one selected Core Audio output device via AUHAL.
/// There is no audio input, pass-through, or second output path that could form a software feedback loop.
/// Rendering happens in C (TestSignalDSP/test_signal.c); this class only sets parameters, owns the unit,
/// follows the selected device (availability, channel count, sample rate) and steps through channels.
@MainActor
final class TestSignalEngine: ObservableObject {
    enum Signal: String, CaseIterable, Identifiable {
        case pink = "Pink noise", sine = "Sine"
        var id: Self { self }
    }

    enum Target: String, CaseIterable, Identifiable {
        case selected = "Selected channel"
        case speakers = "Step through SSD speakers"
        case channels = "Step through all channels"
        case all = "All channels at once"
        var id: Self { self }
        var steps: Bool { self == .speakers || self == .channels }
    }

    struct Device: Equatable, Sendable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let channels: Int
        let sampleRate: Double
    }

    static let frequencies: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000]

    @Published var signal = Signal.pink { didSet { pushParameters() } }
    @Published var levelDB = -20.0 { didSet { pushParameters() } }
    @Published var frequency = 1000.0 { didSet { pushParameters() } }
    @Published var target = Target.selected { didSet { DebugLog.shared.add("Test signal target: \(target.rawValue)"); retarget() } }
    @Published var dwell = 1.0 { didSet { retarget() } }
    @Published var selectedDeviceUID = DriverController.deviceUID {
        didSet {
            guard selectionInitialized, selectedDeviceUID != oldValue else { return }
            stop(fade: false)
            if selectedDeviceUID != DriverController.deviceUID, target == .all { target = .selected }
            if selectedDeviceUID != DriverController.deviceUID, levelDB > -40 {
                levelDB = -40
                DebugLog.shared.add("External test output level limited to -40 dBFS on selection")
            }
            UserDefaults.standard.set(selectedDeviceUID, forKey: Self.outputUIDKey)
            DebugLog.shared.add("Test signal output selected: \(selectedDeviceUID)")
            apply(availableDevices, force: true)
        }
    }
    /// The app-wide selection (input for `.selected`).
    var selectedChannel: Int? { didSet { if target == .selected { retarget() } } }
    /// Distinct channels of the enabled, unmuted SSD speakers, ascending (input for `.speakers`).
    var speakerChannels: [Int] = [] { didSet { if target == .speakers, speakerChannels != oldValue { retarget() } } }

    @Published private(set) var playing = false
    @Published private(set) var availableDevices: [Device] = []
    /// nil when the selected output device is unavailable.
    @Published private(set) var device: Device?
    /// The single channel being played; nil when silent or playing all channels.
    @Published private(set) var currentChannel: Int?
    @Published private(set) var failure: String?

    private var unit: AudioUnit?
    private var state: OpaquePointer?          // TSGState *, owned together with `unit`
    private var stepTimer: Timer?
    private var activity: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice: AudioObjectID?
    private static let outputUIDKey = "testSignalOutputDeviceUID"
    private var selectionInitialized = false

    private nonisolated static let systemAddresses = [
        address(kAudioHardwarePropertyDevices),
        address(kAudioHardwarePropertyServiceRestarted),   // coreaudiod restarted (driver ON/OFF/Update)
    ]
    private nonisolated static let deviceAddresses = [
        address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        address(kAudioDevicePropertyNominalSampleRate),
    ]

    init(restoreOutputSelection: Bool = true) {
        if restoreOutputSelection,
           let saved = UserDefaults.standard.string(forKey: Self.outputUIDKey), !saved.isEmpty {
            selectedDeviceUID = saved
        }
        if selectedDeviceUID != DriverController.deviceUID { levelDB = -40 }
        selectionInitialized = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            let restarted = UnsafeBufferPointer(start: addresses, count: Int(count))
                .contains { $0.mSelector == kAudioHardwarePropertyServiceRestarted }
            Task { @MainActor in self?.rebind(force: restarted) }
        }
        for var addr in Self.systemAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
        systemListener = listener
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(fade: false) } // synchronously: the process exits right after
        }
        rebind(force: true)
    }

    deinit {
        if let systemListener {
            for var addr in Self.systemAddresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, systemListener)
            }
        }
        if let deviceListener, let listenedDevice {
            for var addr in Self.deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &addr, .main, deviceListener)
            }
        }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        stepTimer?.invalidate()
        Self.dispose(unit, state)
    }

    // MARK: - control

    func start() {
        guard !playing else { return }
        guard let device else {
            failure = "Selected output device is unavailable"
            DebugLog.shared.add(failure!)
            return
        }
        guard selectedDeviceUID == DriverController.deviceUID || target != .all else {
            failure = "All channels at once is unavailable for external outputs"
            DebugLog.shared.add(failure!)
            return
        }
        DebugLog.shared.add("Test signal start: \(device.name) [\(device.uid)], \(signal.rawValue), \(Int(levelDB)) dBFS, target \(target.rawValue)")
        playing = true
        failure = nil
        // Keeps the step timer on time while the window is hidden (App Nap).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Test signal output")
        openUnit()
        if unit == nil {
            playing = false
            activity.map(ProcessInfo.processInfo.endActivity)
            activity = nil
            DebugLog.shared.add("Test signal output did not start: \(failure ?? "output unit unavailable")")
        }
        retarget()
    }

    /// `fade: false` stops at once (window close, app quit, device change).
    func stop(fade: Bool = true) {
        guard playing else { return }
        DebugLog.shared.add("Test signal stopped")
        playing = false
        failure = nil
        activity.map(ProcessInfo.processInfo.endActivity)
        activity = nil
        retarget()
        closeUnit(fade: fade)
    }

    // MARK: - channel selection

    private func stepList(_ channelCount: Int) -> [Int] {
        switch target {
        case .speakers: return speakerChannels.filter { $0 <= channelCount }
        case .channels: return channelCount > 0 ? Array(1...channelCount) : []
        case .selected, .all: return []
        }
    }

    /// Recomputes what to play after any change of target, inputs, device or play state.
    private func retarget() {
        stepTimer?.invalidate()
        stepTimer = nil
        let n = device?.channels ?? 0
        guard playing, n > 0 else {
            currentChannel = nil
            send(TSG_CHANNEL_NONE)
            return
        }
        switch target {
        case .all:
            guard selectedDeviceUID == DriverController.deviceUID else {
                currentChannel = nil
                send(TSG_CHANNEL_NONE)
                DebugLog.shared.add("External output: all channels at once blocked")
                return
            }
            currentChannel = nil
            send(TSG_CHANNEL_ALL)
            DebugLog.shared.add("Routing to all \(n) channels")
            return
        case .selected:
            currentChannel = selectedChannel.flatMap { (1...n).contains($0) ? $0 : nil }
        case .speakers, .channels:
            let list = stepList(n)
            DebugLog.shared.add("Step list: \(list.isEmpty ? "empty" : list.map(String.init).joined(separator: ", ")) (device \(n) ch)")
            if !list.contains(currentChannel ?? 0) { currentChannel = list.first }
            if list.count > 1 {
                let timer = Timer(timeInterval: dwell, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.step() }
                }
                RunLoop.main.add(timer, forMode: .common) // keep stepping while a control is being dragged
                stepTimer = timer
            }
        }
        send(currentChannel.map(Int32.init) ?? TSG_CHANNEL_NONE)
        DebugLog.shared.add(currentChannel.map { "Routing to ch \($0)" } ?? "No valid target channel; output silent")
    }

    private func step() {
        let list = stepList(device?.channels ?? 0)
        currentChannel = list.first { $0 > currentChannel ?? 0 } ?? list.first
        send(currentChannel.map(Int32.init) ?? TSG_CHANNEL_NONE)
        DebugLog.shared.add(currentChannel.map { "Step to ch \($0)" } ?? "Step list empty; output silent")
    }

    private func send(_ channel: Int32) {
        if let state { tsgSetChannel(state, channel) }
    }

    private func pushParameters() {
        guard let state else { return }
        tsgSetSignal(state, signal == .sine ? TSG_SINE : TSG_PINK)
        tsgSetLevel(state, Float(levelDB))
        tsgSetFrequency(state, Float(frequency))
    }

    // MARK: - device and output unit

    /// Re-enumerates output devices. `force` also rebuilds when it looks unchanged (its format changed, or
    /// coreaudiod restarted and may have reused the object ID).
    private var rebindGeneration = 0

    /// findDevices() blocks while coreaudiod is busy (right after a driver ON/Update restart it can take
    /// minutes), so it runs off the main thread; only the newest lookup is applied.
    private func rebind(force: Bool) {
        rebindGeneration += 1
        let generation = rebindGeneration
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.findDevices() }.value
            guard let self, generation == self.rebindGeneration else { return }
            self.apply(found, force: force)
        }
    }

    private func apply(_ found: [Device], force: Bool) {
        availableDevices = found
        let selected = found.first { $0.uid == selectedDeviceUID }
        guard force || selected != device else { return }
        if playing { stop(fade: false) }
        DebugLog.shared.add(selected.map { "Test output: \($0.name) [\($0.uid)], \($0.channels) ch @ \(Int($0.sampleRate)) Hz" }
                            ?? "Selected test output unavailable: \(selectedDeviceUID)")
        if let deviceListener, let listenedDevice {
            for var addr in Self.deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &addr, .main, deviceListener)
            }
        }
        listenedDevice = nil
        closeUnit(fade: false)
        device = selected
        if let selected {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.rebind(force: true) }
            }
            for var addr in Self.deviceAddresses {
                AudioObjectAddPropertyListenerBlock(selected.id, &addr, .main, listener)
            }
            deviceListener = listener
            listenedDevice = selected.id
        }
        retarget()
    }

    private func openUnit() {
        guard unit == nil, let device else { return }
        guard let state = tsgCreate(device.sampleRate) else {
            failure = "Test signal: could not create the signal generator"
            DebugLog.shared.add(failure!)
            return
        }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        var deviceID = device.id
        // Float32, non-interleaved, the device's own channel count and rate: no conversion in AUHAL.
        var format = AudioStreamBasicDescription(
            mSampleRate: device.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(device.channels), mBitsPerChannel: 32, mReserved: 0)
        var callback = tsgRenderCallback(state)

        func ok(_ status: OSStatus, _ what: String) -> Bool {
            if status != noErr {
                failure = "Test signal: \(what) failed (OSStatus \(status))"
                DebugLog.shared.add(failure!)
            }
            return status == noErr
        }
        guard let component = AudioComponentFindNext(nil, &desc),
              ok(AudioComponentInstanceNew(component, &instance), "creating the output unit"), let au = instance,
              ok(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "selecting the device"),
              ok(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                      &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "setting the format"),
              ok(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                      &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "setting the callback"),
              ok(AudioUnitInitialize(au), "initializing the output unit")
        else {
            if failure == nil {
                failure = "Test signal: AUHAL output unavailable"
                DebugLog.shared.add(failure!)
            }
            Self.dispose(instance, state)
            return
        }
        unit = au
        self.state = state
        pushParameters()
        guard ok(AudioOutputUnitStart(au), "starting output") else {
            closeUnit(fade: false)
            return
        }
        failure = nil
        DebugLog.shared.add("Audio output unit started: \(device.name) [\(device.uid)]")
    }

    private func closeUnit(fade: Bool) {
        guard let unit, let state else { return }
        self.unit = nil
        self.state = nil
        guard fade else { return Self.dispose(unit, state) }
        tsgSetChannel(state, TSG_CHANNEL_NONE)
        // A new unit started meanwhile has its own state, so this one can finish its fade-out alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { Self.dispose(unit, state) }
    }

    /// Stops and disposes the unit, then frees its render state (the IO thread no longer uses it).
    private nonisolated static func dispose(_ unit: AudioUnit?, _ state: OpaquePointer?) {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        if let state { tsgDestroy(state) }
    }

    // MARK: - Core Audio queries

    private nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func findDevices() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &addr, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap(deviceInfo).sorted { lhs, rhs in
            if lhs.uid == DriverController.deviceUID { return true }
            if rhs.uid == DriverController.deviceUID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private nonisolated static func stringProperty(_ id: AudioObjectID,
                                                   _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = address(selector)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value.map { $0 as String } : nil
    }

    private nonisolated static func deviceInfo(_ id: AudioObjectID) -> Device? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }

        addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0 ? Device(id: id, uid: uid, name: name, channels: channels, sampleRate: rate) : nil
    }
}

// MARK: - CLI

extension TestSignalEngine {
    /// Read-only device inventory for checking the same Core Audio enumeration used by the GUI.
    static func listOutputsCLI() -> Never {
        Task { @MainActor in
            let outputs = await Task.detached(priority: .userInitiated) { Self.findDevices() }.value
            for output in outputs {
                print("\(output.name) | \(output.channels) ch @ \(Int(output.sampleRate)) Hz | \(output.uid)")
            }
            exit(0)
        }
        RunLoop.main.run()
        fatalError("Main run loop exited before device enumeration")
    }

    /// `VisualizerApp --test-signal <channel> <seconds> [pink|sine] [dBFS]`: plays without a window, then exits.
    static func runCLI(_ args: [String]) -> Never {
        let usage = "usage: VisualizerApp --test-signal <channel> <seconds> [pink|sine] [dBFS (-60...0, default -20)]"
        guard args.count >= 2, let channel = Int(args[0]), channel >= 1, let seconds = Double(args[1]), seconds > 0,
              args.count < 3 || ["pink", "sine"].contains(args[2]),
              args.count < 4 || Double(args[3]).map({ (-60...0).contains($0) }) == true else {
            print(usage)
            exit(2)
        }
        let engine = TestSignalEngine(restoreOutputSelection: false)
        engine.signal = args.count > 2 && args[2] == "sine" ? .sine : .pink
        engine.levelDB = args.count > 3 ? Double(args[3])! : -20
        engine.selectedChannel = channel
        let lookupDeadline = Date().addingTimeInterval(15) // the device lookup is asynchronous; coreaudiod may be busy
        while engine.device == nil, Date() < lookupDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard let device = engine.device else {
            print("test-signal: virtual device \(DriverController.deviceUID) not found (driver OFF?)")
            exit(1)
        }
        guard channel <= device.channels else {
            print("test-signal: channel \(channel) is outside the device's \(device.channels) channels")
            exit(2)
        }
        engine.start()
        if let failure = engine.failure {
            print(failure)
            exit(1)
        }
        print("test-signal: ch \(channel), \(engine.signal.rawValue.lowercased()), \(Int(engine.levelDB)) dBFS, \(seconds) s"
              + " -> \(device.channels) ch @ \(Int(device.sampleRate)) Hz")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        engine.stop()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) // let the fade-out finish
        print("test-signal: stopped")
        exit(0)
    }
}
