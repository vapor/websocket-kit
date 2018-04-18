extension HTTPClient {
    /// Performs an HTTP protocol upgrade to WebSocket protocol `HTTPClient`.
    ///
    ///     let worker = MultiThreadedEventLoopGroup(numThreads: 1)
    ///     let webSocket = try HTTPClient.webSocket(hostname: "echo.websocket.org", on: worker).wait()
    ///     webSocket.onText { ws, text in
    ///         print("server said: \(text))
    ///     }
    ///     webSocket.send("Hello, world!")
    ///     try webSocket.onClose.wait()
    ///
    /// - parameters:
    ///     - scheme: Transport layer security to use, either tls or plainText.
    ///     - hostname: Remote server's hostname.
    ///     - port: Remote server's port, defaults to 80 for TCP and 443 for TLS.
    ///     - path: Path on remote server to connect to.
    ///     - worker: `Worker` to perform async work on.
    /// - returns: A `Future` containing the connected `HTTPClient`.
    public static func webSocket(
        scheme: HTTPScheme = .ws,
        hostname: String,
        port: Int? = nil,
        path: String = "/",
        on worker: Worker
    ) -> Future<WebSocket> {
        let upgrader = WebSocketClientUpgrader(hostname: hostname, path: path)
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

    /// Creates a new `WebSocketClientUpgrader`.
    init(hostname: String, path: String) {
        self.hostname = hostname
        self.path = path
    }

    /// See `HTTPClientProtocolUpgrader`.
    func buildUpgradeRequest() -> HTTPRequestHead {
        var upgradeReq = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: path)
        upgradeReq.headers.add(name: .connection, value: "Upgrade")
        upgradeReq.headers.add(name: .upgrade, value: "websocket")
        upgradeReq.headers.add(name: .host, value: hostname)
        upgradeReq.headers.add(name: .origin, value: "vapor/websocket")
        upgradeReq.headers.add(name: "Sec-WebSocket-Version", value: "13") // fixme: randomly gen
        upgradeReq.headers.add(name: "Sec-WebSocket-Key", value: "MTMtMTUyMzk4NDIxNzk3NQ==") // fixme: randomly gen
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
