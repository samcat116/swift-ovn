// swift-tools-version: 6.0
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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 2.37.0 requires Swift tools 6.1; stay below it while this package
        // and CI build with Swift 6.0.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", "2.26.0"..<"2.37.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SwiftOVN",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
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
            dependencies: ["SwiftOVN"]
        ),
    ]
)