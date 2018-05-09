// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "WebSocket",
    products: [
        .library(name: "WebSocket", targets: ["WebSocket"]),
    ],
    dependencies: [
        // 🌎 Utility package containing tools for byte manipulation, Codable, OS APIs, and debugging.
        .package(url: "https://github.com/vapor/core.git", from: "3.0.0"),

        // 🔑 Hashing (BCrypt, SHA2, HMAC), encryption (AES), public-key (RSA), and random data generation.
        .package(url: "https://github.com/vapor/crypto.git", from: "3.0.0"),
        
        // 🚀 Non-blocking, event-driven HTTP for Swift built on Swift NIO.
        .package(url: "https://github.com/vapor/http.git", from: "3.0.0"),
        
        // Event-driven network application framework for high performance protocol servers & clients, non-blocking.
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.4.0"),

        // Bindings to OpenSSL-compatible libraries for TLS support in SwiftNIO
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "1.0.1"),
    ],
    targets: [
        .target(name: "WebSocket", dependencies: ["Core", "Crypto", "HTTP", "NIO", "NIOWebSocket"]),
        .testTarget(name: "WebSocketTests", dependencies: ["WebSocket"]),
    ]
)
