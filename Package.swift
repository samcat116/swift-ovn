// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftOVN",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftOVN",
            targets: ["SwiftOVN"]),
    ],
    dependencies: [
        // 2.98.0 is the floor swift-nio-ssl 2.37.1 itself requires.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.98.0"),
        // 2.37.1+ leads its default TLS group list with X25519MLKEM768, so
        // consumers negotiate hybrid post-quantum key exchange. Do not lower
        // this floor. Requires Swift tools 6.1+, hence the 6.2 tools version.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "SwiftOVN",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "BasicUsage",
            dependencies: ["SwiftOVN"],
            path: "Examples"
        ),
        .testTarget(
            name: "SwiftOVNTests",
            dependencies: [
                "SwiftOVN",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
    ]
)