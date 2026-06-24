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
        .package(url: "https://github.com/mattt/ollama-swift.git", from: "1.8.0"),
        // SQLite store + FTS5 full-text search for on-device chat history. Lives in
        // the pure-logic package so the persistence layer is host-testable (GRDB is
        // not SwiftUI/UIKit). GRDBQuery (the SwiftUI @Query layer) stays app-only.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "PhantasmKit",
            dependencies: [
                .product(name: "Ollama", package: "ollama-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
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
