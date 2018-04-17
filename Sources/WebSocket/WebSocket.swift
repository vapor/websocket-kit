/// Represents a client connected via WebSocket protocol.
/// Use this to receive text/data frames and send responses.
///
///      ws.onText { ws, string in
///         ws.send(string.reversed())
///      }
///
public final class WebSocket: WebSocketEventHandler {
    /// `true` if the `WebSocket` has been closed.
    public private(set) var isClosed: Bool

    /// Outbound `WebSocketEventHandler`.
    private let eventHandler: WebSocketEventHandler

    /// See `onText(...)`.
    private var _onText: (WebSocket, String) -> ()

    /// See `onData(...)`.
    private var _onData: (WebSocket, Data) -> ()

    /// See `onClose(...)`.
    private var _onClose: (WebSocket) -> ()

    /// See `onError(...)`.
    private var _onError: (WebSocket, Error) -> ()

    /// Creates a new `WebSocket` using the supplied `WebSocketEventHandler`.
    /// Use `httpProtocolUpgrader(...)` to create a protocol upgrader that can create `WebSocket`s.
    internal init(eventHandler: WebSocketEventHandler) {
        self.eventHandler = eventHandler
        self.isClosed = false
        self._onText = { _, _ in }
        self._onData = { _, _ in }
        self._onClose = { _ in }
        self._onError = { _, _ in }
    }

    /// Adds a callback to this `WebSocket` to receive text-formatted messages.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// Use `onData(callback:)` to handle binary-formatted messages.
    ///
    /// - parameters:
    ///     - callback: Closure to accept incoming text-formatted data.
    ///                 This will be called every time the connected client sends text.
    public func onText(_ callback: @escaping (WebSocket, String) -> ()) {
        _onText = callback
    }

    /// Adds a callback to this `WebSocket` to receive binary-formatted messages.
    ///
    ///     ws.onText { ws, data in
    ///         print(data)
    ///     }
    ///
    /// Use `onText(callback:)` to handle text-formatted messages.
    ///
    /// - parameters:
    ///     - callback: Closure to accept incoming binary-formatted data.
    ///                 This will be called every time the connected client sends binary-data.
    public func onData(_ callback: @escaping (WebSocket, Data) -> ()) {
        _onData = callback
    }

    /// Adds a callback to this `WebSocket` that will be called when the connection closes.
    ///
    ///     ws.onClose { ws in
    ///         // client has disconnected
    ///     }
    ///
    /// - parameters:
    ///     - callback: Closure that will be called when this connection closes.
    public func onClose(_ callback: @escaping (WebSocket) -> ()) {
        _onClose = callback
    }

    /// Adds a callback to this `WebSocket` to handle errors.
    ///
    ///     ws.onError { ws, error in
    ///         print(error)
    ///     }
    ///
    /// - parameters:
    ///     - callback: Closure to handle error's caught during this connection.
    public func onError(_ callback: @escaping (WebSocket, Error) -> ()) {
        _onError = callback
    }

    /// Sends text-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - text: `String` to send as text-formatted data to the client.
    public func send(_ text: String) {
        guard !isClosed else { return }
        eventHandler.webSocketEvent(.text(text))
    }

    /// Sends text-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - text: `String` to send as text-formatted data to the client.
    public func send(_ text: [Character]) {
        send(String(text))
    }

    /// Sends binary-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - data: `Data` to send as binary-formatted data to the client.
    public func send(_ data: Data) {
        guard !isClosed else { return }
        eventHandler.webSocketEvent(.binary(data))
    }

    /// Closes the `WebSocket`'s connection, disconnecting the client.
    public func close() {
        guard !isClosed else {
            return
        }
        eventHandler.webSocketEvent(.close)
    }

    /// See `WebSocketEventHandler`.
    internal func webSocketEvent(_ event: WebSocketEvent) {
        switch event {
        case .binary(let data): _onData(self, data)
        case .text(let text): _onText(self, text)
        case .close: _onClose(self)
        case .error(let err): _onError(self, err)
        case .connect: break
        }
    }
}
