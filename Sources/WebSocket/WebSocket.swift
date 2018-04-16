import HTTP
import Foundation

/// Represents a client connected via WebSocket protocol.
/// Use this to receive text/data frames and send responses.
///
///      ws.onText { string in
///         ws.send(string.reversed())
///     }
///
public final class WebSocket {
    /// The internal NIO channel pipeline handler.
    private let handler: WebsocketHandler

    /// `true` if the `WebSocket` has been closed.
    public private(set) var isClosed: Bool

    /// Creates a new `WebSocket` on the supplied handler.
    internal init(handler: WebsocketHandler) {
        self.handler = handler
        self.isClosed = false
    }

    /// Adds a callback to this `WebSocket` to receive text-formatted messages.
    ///
    ///     ws.onText { string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// Use `onData(callback:)` to handle binary-formatted messages.
    ///
    /// - parameters:
    ///     - callback: Closure to accept incoming text-formatted data.
    ///                 This will be called every time the connected client sends text.
    public func onText(_ callback: @escaping (String) -> ()) {
        self.handler.onText = callback
    }

    /// Adds a callback to this `WebSocket` to receive binary-formatted messages.
    ///
    ///     ws.onText { data in
    ///         print(data)
    ///     }
    ///
    /// Use `onText(callback:)` to handle text-formatted messages.
    ///
    /// - parameters:
    ///     - callback: Closure to accept incoming binary-formatted data.
    ///                 This will be called every time the connected client sends binary-data.
    public func onData(_ callback: @escaping (Data) -> ()) {
        self.handler.onData = callback
    }

    /// Adds a callback to this `WebSocket` that will be called when the connection closes.
    ///
    ///     ws.onClose {
    ///         // client has disconnected
    ///     }
    ///
    /// - parameters:
    ///     - callback: Closure that will be called when this connection closes.
    public func onClose(_ callback: @escaping () -> ()) {
        self.handler.onClose = callback
    }

    /// Adds a callback to this `WebSocket` to handle errors.
    ///
    ///     ws.onError { error in
    ///         print(error)
    ///     }
    ///
    /// - parameters:
    ///     - callback: Closure to handle error's caught during this connection.
    public func onError(_ callback: @escaping (Error) -> ()) {
        self.handler.onError = callback
    }

    /// Sends text-formatted data to the connected client.
    ///
    ///     ws.onText { string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - text: `String` to send as text-formatted data to the client.
    public func send(_ text: String) {
        guard !isClosed else { return }
        handler.send(count: text.count, opcode: .text) { buffer in
            buffer.write(string: text)
        }
    }

    /// Sends text-formatted data to the connected client.
    ///
    ///     ws.onText { string in
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
    ///     ws.onText { string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - data: `Data` to send as binary-formatted data to the client.
    public func send(_ data: Data) {
        handler.send(count: data.count, opcode: .binary) { buffer in
            buffer.write(bytes: data)
        }
    }

    /// Closes the `WebSocket`'s connection, disconnecting the client.
    public func close() {
        guard !isClosed else {
            return
        }
        handler.close()
    }
}
