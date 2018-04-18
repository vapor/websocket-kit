/// Allows `HTTPServer` to accept `WebSocket` connections.
///
///     let ws = HTTPServer.webSocketUpgrader(shouldUpgrade: { req in
///         // return non-nil HTTPHeaders to allow upgrade
///     }, onUpgrade: { ws, req in
///         // setup callbacks or send data to connected WebSocket
///     })
///
///     HTTPServer.start(..., upgraders: [ws])
///
extension HTTPServer {
    // MARK: Server Upgrade

    /// Creates an `HTTPProtocolUpgrader` that will accept incoming `WebSocket` upgrade requests.
    ///
    ///     let ws = HTTPServer.webSocketUpgrader(shouldUpgrade: { req in
    ///         // return non-nil HTTPHeaders to allow upgrade
    ///     }, onUpgrade: { ws, req in
    ///         // setup callbacks or send data to connected WebSocket
    ///     })
    ///
    ///     HTTPServer.start(..., upgraders: [ws])
    ///
    public static func webSocketUpgrader(
        shouldUpgrade: @escaping (HTTPRequest) -> (HTTPHeaders?),
        onUpgrade: @escaping (WebSocket, HTTPRequest) -> ()
    ) -> HTTPProtocolUpgrader {
        return WebSocketUpgrader(shouldUpgrade: { head in
            let req = HTTPRequest(
                method: head.method,
                url: head.uri,
                version: head.version,
                headers: head.headers
            )
            return shouldUpgrade(req)
        }, upgradePipelineHandler: { channel, head in
            var req = HTTPRequest(
                method: head.method,
                url: head.uri,
                version: head.version,
                headers: head.headers
            )
            req.channel = channel
            let webSocket = WebSocket(channel: channel)
            return channel.pipeline.add(webSocket: webSocket).map {
                onUpgrade(webSocket, req)
            }
        })
    }
}
