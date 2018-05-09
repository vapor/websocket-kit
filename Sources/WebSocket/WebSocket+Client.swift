import Crypto

/// Allows `HTTPClient` to be used to create `WebSocket` connections.
///
///     let ws = try HTTPClient.webSocket(hostname: "echo.websocket.org", on: ...).wait()
///     ws.onText { ws, text in
///         print("server said: \(text)")
///     }
///     ws.send("Hello, world!")
///     try ws.onClose.wait()
///
extension HTTPClient {
    // MARK: Client Upgrade

    /// Performs an HTTP protocol upgrade to` WebSocket` protocol `HTTPClient`.
    ///
    ///     let ws = try HTTPClient.webSocket(hostname: "echo.websocket.org", on: ...).wait()
    ///     ws.onText { ws, text in
    ///         print("server said: \(text)")
    ///     }
    ///     ws.send("Hello, world!")
    ///     try ws.onClose.wait()
    ///
    /// - parameters:
    ///     - scheme: Transport layer security to use, either tls or plainText.
    ///     - hostname: Remote server's hostname.
    ///     - port: Remote server's port, defaults to 80 for TCP and 443 for TLS.
    ///     - path: Path on remote server to connect to.
    ///     - headers: Additional HTTP headers are used to establish a connection.
    ///     - worker: `Worker` to perform async work on.
    /// - returns: A `Future` containing the connected `WebSocket`.
    public static func webSocket(
        scheme: HTTPScheme = .ws,
        hostname: String,
        port: Int? = nil,
        path: String = "/",
        headers: HTTPHeaders = .init(),
        on worker: Worker
    ) -> Future<WebSocket> {
        let upgrader = WebSocketClientUpgrader(hostname: hostname, path: path, headers: headers)
        return HTTPClient.upgrade(scheme: scheme, hostname: hostname, port: port, upgrader: upgrader, on: worker)
    }
}

// MARK: Private

/// Private `HTTPClientProtocolUpgrader` for use with `HTTPClient.upgrade(...)`.
private final class WebSocketClientUpgrader: HTTPClientProtocolUpgrader {
    /// Hostname being connected to.
    let hostname: String

    /// Path to use when upgrading.
    let path: String
    
    /// Additional headers to use when upgrading.
    let headers: HTTPHeaders

    /// Creates a new `WebSocketClientUpgrader`.
    init(hostname: String, path: String, headers: HTTPHeaders) {
        self.hostname = hostname
        self.path = path
        self.headers = headers
    }

    /// See `HTTPClientProtocolUpgrader`.
    func buildUpgradeRequest() -> HTTPRequestHead {
        var upgradeReq = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: path)
        headers.forEach { upgradeReq.headers.replaceOrAdd(name: $0.name, value: $0.value) }
        upgradeReq.headers.add(name: .connection, value: "Upgrade")
        upgradeReq.headers.add(name: .upgrade, value: "websocket")
        upgradeReq.headers.add(name: .host, value: hostname)
        upgradeReq.headers.add(name: .origin, value: "vapor/websocket")
        upgradeReq.headers.add(name: .secWebSocketVersion, value: "13")
        do {
            let webSocketKey = try CryptoRandom().generateData(count: 16).base64EncodedString()
            upgradeReq.headers.add(name: .secWebSocketKey, value: webSocketKey)
        } catch {
            print("[WebSocket] [Upgrader] Could not generate random value for Sec-WebSocket-Key header: \(error)")
        }
        return upgradeReq
    }

    /// See `HTTPClientProtocolUpgrader`.
    func isValidUpgradeResponse(_ upgradeRes: HTTPResponseHead) -> Bool {
        switch upgradeRes.status {
        case .switchingProtocols:
            // fixme: do additional checks
            return true
        default: return false
        }
    }

    /// See `HTTPClientProtocolUpgrader`.
    func upgrade(ctx: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> Future<WebSocket> {
        let webSocket = WebSocket(channel: ctx.channel)
        return ctx.channel.pipeline.addHandlers(WebSocketFrameEncoder(), WebSocketFrameDecoder(), first: false).then {
            return ctx.channel.pipeline.add(webSocket: webSocket)
        }.map(to: WebSocket.self) {
            return webSocket
        }
    }
}
