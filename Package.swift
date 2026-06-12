// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiveTranscriber",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "LiveTranscriber",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "scribe-test",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/SelfTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
