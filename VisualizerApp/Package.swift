// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VirtualAudioVisualizer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SSDBridge", cxxSettings: [.headerSearchPath("include")]),
        .target(name: "AudioBridge"),
        .target(name: "TestSignalDSP"),
        .executableTarget(
            name: "VisualizerApp",
            dependencies: ["SSDBridge", "AudioBridge", "TestSignalDSP"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
