// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResearchCopilot",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CopilotCore", targets: ["CopilotCore"]),
        .executable(name: "ResearchCopilot", targets: ["ResearchCopilot"]),
        .executable(name: "CopilotDiagnostics", targets: ["CopilotDiagnostics"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .target(name: "CopilotCore"),
        .target(name: "CopilotSpeech", dependencies: ["CopilotCore", .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        .executableTarget(name: "ResearchCopilot", dependencies: ["CopilotCore", "CopilotSpeech"]),
        .executableTarget(name: "CopilotDiagnostics", dependencies: ["CopilotCore", "CopilotSpeech"]),
        .testTarget(name: "CopilotCoreTests", dependencies: ["CopilotCore"]),
        .testTarget(name: "CopilotSpeechTests", dependencies: ["CopilotSpeech"]),
        .testTarget(name: "ResearchCopilotTests", dependencies: ["ResearchCopilot"])
    ]
)
