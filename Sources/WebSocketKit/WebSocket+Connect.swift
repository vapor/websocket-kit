import NIOCore
import NIOHTTP1
import Foundation

extension WebSocket {
    /// Establish a WebSocket connection.
    ///
    /// - Parameters:
    ///   - url: URL for the WebSocket server.
    ///   - headers: Headers to send to the WebSocket server.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgrade: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`.
    /// - Returns: A future which completes when the connection to the WebSocket server is established.
    @preconcurrency
    public static func connect(
        to url: String,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        guard let url = URL(string: url) else {
            return eventLoopGroup.any().makeFailedFuture(WebSocketClient.Error.invalidURL)
        }
        return self.connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: onUpgrade
        )
    }

    /// Establish a WebSocket connection.
    ///
    /// - Parameters:
    ///   - url: URL for the WebSocket server.
    ///   - headers: Headers to send to the WebSocket server.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgrade: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`.
    /// - Returns: A future which completes when the connection to the WebSocket server is established.
    @preconcurrency
    public static func connect(
        to url: URL,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        let scheme = url.scheme ?? "ws"
        return self.connect(
            scheme: scheme,
            host: url.host ?? "localhost",
            port: url.port ?? (scheme == "wss" ? 443 : 80),
            path: url.path,
            query: url.query,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: onUpgrade
        )
    }

    /// Establish a WebSocket connection.
    ///
    /// - Parameters:
    ///   - scheme: Scheme component of the URI for the WebSocket server.
    ///   - host: Host component of the URI for the WebSocket server.
    ///   - port: Port on which to connect to the WebSocket server.
    ///   - path: Path component of the URI for the WebSocket server.
    ///   - query: Query component of the URI for the WebSocket server.
    ///   - headers: Headers to send to the WebSocket server.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgrade: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`.
    /// - Returns: A future which completes when the connection to the WebSocket server is established.
    @preconcurrency
    public static func connect(
        scheme: String = "ws",
        host: String,
        port: Int = 80,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return WebSocketClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: configuration
        ).connect(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            query: query,
            headers: headers,
            onUpgrade: onUpgrade
        )
    }

    /// Establish a WebSocket connection via a proxy server.
    ///
    /// - Parameters:
    ///   - scheme: Scheme component of the URI for the origin server.
    ///   - host: Host component of the URI for the origin server.
    ///   - port: Port on which to connect to the origin server.
    ///   - path: Path component of the URI for the origin server.
    ///   - query: Query component of the URI for the origin server.
    ///   - headers: Headers to send to the origin server.
    ///   - proxy: Host component of the URI for the proxy server.
    ///   - proxyPort: Port on which to connect to the proxy server.
    ///   - proxyHeaders: Headers to send to the proxy server.
    ///   - proxyConnectDeadline: Deadline for establishing the proxy connection.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgrade: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`.
    /// - Returns: A future which completes when the connection to the origin server is established.
    @preconcurrency
    public static func connect(
        scheme: String = "ws",
        host: String,
        port: Int = 80,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        proxy: String?,
        proxyPort: Int? = nil,
        proxyHeaders: HTTPHeaders = [:],
        proxyConnectDeadline: NIODeadline = NIODeadline.distantFuture,
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return WebSocketClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: configuration
        ).connect(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            query: query,
            headers: headers,
            proxy: proxy,
            proxyPort: proxyPort,
            proxyHeaders: proxyHeaders,
            proxyConnectDeadline: proxyConnectDeadline,
            onUpgrade: onUpgrade
        )
    }


    /// Description
    /// - Parameters:
    ///   - url: URL for the origin server.
    ///   - headers: Headers to send to the origin server.
    ///   - proxy: Host component of the URI for the proxy server.
    ///   - proxyPort: Port on which to connect to the proxy server.
    ///   - proxyHeaders: Headers to send to the proxy server.
    ///   - proxyConnectDeadline: Deadline for establishing the proxy connection.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgrade: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`.
    /// - Returns: A future which completes when the connection to the origin server is established.
    @preconcurrency
    public static func connect(
        to url: String,
        headers: HTTPHeaders = [:],
        proxy: String?,
        proxyPort: Int? = nil,
        proxyHeaders: HTTPHeaders = [:],
        proxyConnectDeadline: NIODeadline = NIODeadline.distantFuture,
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        guard let url = URL(string: url) else {
            return eventLoopGroup.any().makeFailedFuture(WebSocketClient.Error.invalidURL)
        }
        let scheme = url.scheme ?? "ws"
        return self.connect(
            scheme: scheme,
            host: url.host ?? "localhost",
            port: url.port ?? (scheme == "wss" ? 443 : 80),
            path: url.path,
            query: url.query,
            headers: headers,
            proxy: proxy,
            proxyPort: proxyPort,
            proxyHeaders: proxyHeaders,
            proxyConnectDeadline: proxyConnectDeadline,
            on: eventLoopGroup,
            onUpgrade: onUpgrade
        )
    }
}
