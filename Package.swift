// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "websocket-kit",
    products: [
        .library(name: "WebSocketKit", targets: ["WebSocketKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "WebSocketKit", dependencies: [
            "NIO",
            "NIOConcurrencyHelpers",
            "NIOFoundationCompat",
            "NIOHTTP1",
            "NIOSSL",
            "NIOWebSocket"
        ]),
        .testTarget(name: "WebSocketKitTests", dependencies: ["WebSocketKit"]),
    ]
)
