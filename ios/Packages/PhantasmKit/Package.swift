// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhantasmKit",
    // macOS is included so the pure-logic tests run on the host via `swift test`
    // (SwiftData requires macOS 14+). The app itself targets iOS 17+.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhantasmKit", targets: ["PhantasmKit"])
    ],
    targets: [
        .target(
            name: "PhantasmKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhantasmKitTests",
            dependencies: ["PhantasmKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
