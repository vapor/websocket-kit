// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "websocket-kit",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "WebSocketKit", targets: ["WebSocketKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.33.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.14.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.11.4"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(name: "WebSocketKit", dependencies: [
            "CZlib",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            .product(name: "Atomics", package: "swift-atomics")
        ]),
        .target(
            name: "CZlib",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("z")
            ]),
        .testTarget(name: "WebSocketKitTests", dependencies: [
            .target(name: "WebSocketKit"),
        ]),
    ]
)
