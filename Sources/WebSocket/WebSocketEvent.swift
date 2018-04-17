/// Handles `WebSocketEvent`, either inbound or outbound.
protocol WebSocketEventHandler {
    /// Handles the `WebSocketEvent`.
    func webSocketEvent(_ event: WebSocketEvent)
}

/// Supported `WebSocket` events.
internal enum WebSocketEvent {
    case text(String)
    case binary(Data)
    case error(Error)
    case connect
    case close
}
