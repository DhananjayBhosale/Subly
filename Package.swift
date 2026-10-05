// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Subly",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SublyCaptions", targets: ["SublyCaptions"]),
        .library(name: "SublyEngine", targets: ["SublyEngine"]),
        .executable(name: "SublyApp", targets: ["SublyApp"]),
        .executable(name: "subly-cli", targets: ["subly-cli"]),
        .executable(name: "subly-bench", targets: ["subly-bench"]),
    ],
    targets: [
        // Deterministic core. NO Apple-framework imports beyond Foundation —
        // keeps caption logic unit-testable and portable.
        .target(name: "SublyCaptions"),
        .target(name: "SublyEngine", dependencies: ["SublyCaptions"]),
        // Swift 5 language mode on purpose: Apple's `translationTask` hands over a
        // non-Sendable `TranslationSession`, which Swift 6 strict concurrency
        // rejects. Isolated here so the rest of the app keeps full checking.
        .target(name: "SublyTranslate", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "SublyApp",
            dependencies: ["SublyCaptions", "SublyEngine", "SublyTranslate"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(name: "subly-cli", dependencies: ["SublyCaptions", "SublyEngine"]),
        .executableTarget(name: "subly-bench", dependencies: ["SublyCaptions"]),
        .testTarget(name: "SublyCaptionsTests", dependencies: ["SublyCaptions"]),
        .testTarget(name: "SublyEngineTests", dependencies: ["SublyEngine", "SublyCaptions"]),
    ]
)
