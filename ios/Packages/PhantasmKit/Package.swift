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
    dependencies: [
        .package(url: "https://github.com/mattt/ollama-swift.git", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "PhantasmKit",
            dependencies: [
                .product(name: "Ollama", package: "ollama-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhantasmKitTests",
            dependencies: ["PhantasmKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
