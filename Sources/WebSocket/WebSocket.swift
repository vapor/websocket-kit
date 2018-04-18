/// Represents a client connected via WebSocket protocol.
/// Use this to receive text/data frames and send responses.
///
///      ws.onText { ws, string in
///         ws.send(string.reversed())
///      }
///
public final class WebSocket: BasicWorker {
    /// See `BasicWorker`.
    public var eventLoop: EventLoop {
        return channel.eventLoop
    }

    /// Outbound `WebSocketEventHandler`.
    private let channel: Channel

    /// See `onText(...)`.
    var onTextCallback: (WebSocket, String) -> ()

    /// See `onBinary(...)`.
    var onBinaryCallback: (WebSocket, Data) -> ()

    /// See `onError(...)`.
    var onErrorCallback: (WebSocket, Error) -> ()

    /// Creates a new `WebSocket` using the supplied `Channel`.
    /// Use `httpProtocolUpgrader(...)` to create a protocol upgrader that can create `WebSocket`s.
    internal init(channel: Channel) {
        self.channel = channel
        self.isClosed = false
        self.onTextCallback = { _, _ in }
        self.onBinaryCallback = { _, _ in }
        self.onErrorCallback = { _, _ in }
    }

    // MARK: Receive

    /// Adds a callback to this `WebSocket` to receive text-formatted messages.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// Use `onBinary(_:)` to handle binary-formatted messages.
    ///
    /// - parameters:
    ///     - callback: Closure to accept incoming text-formatted data.
    ///                 This will be called every time the connected client sends text.
    public func onText(_ callback: @escaping (WebSocket, String) -> ()) {
        onTextCallback = callback
    }

    /// Adds a callback to this `WebSocket` to receive binary-formatted messages.
    ///
    ///     ws.onBinary { ws, data in
    ///         print(data)
    ///     }
    ///
    /// Use `onText(_:)` to handle text-formatted messages.
    ///
    /// - parameters:
    ///     - callback: Closure to accept incoming binary-formatted data.
    ///                 This will be called every time the connected client sends binary-data.
    public func onBinary(_ callback: @escaping (WebSocket, Data) -> ()) {
        onBinaryCallback = callback
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
        onErrorCallback = callback
    }

    // MARK: Send

    /// Sends text-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - text: `String` to send as text-formatted data to the client.
    ///     - promise: Optional `Promise` to complete when the send is finished.
    public func send<S>(_ text: S, promise: Promise<Void>? = nil) where S: Collection, S.Element == Character {
        return send(text: String(text), promise: promise)
    }

    /// Sends binary-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send([0x68, 0x69])
    ///     }
    ///
    /// - parameters:
    ///     - text: `Data` to send as binary-formatted data to the client.
    ///     - promise: Optional `Promise` to complete when the send is finished.
    public func send(_ binary: Data, promise: Promise<Void>? = nil) {
        return send(binary: binary, promise: promise)
    }

    /// Sends text-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(text: string.reversed())
    ///     }
    ///
    /// - parameters:
    ///     - text: `LosslessDataConvertible` to send as text-formatted data to the client.
    ///     - promise: Optional `Promise` to complete when the send is finished.
    public func send(text: LosslessDataConvertible, promise: Promise<Void>? = nil) {
        send(text, opcode: .text, promise: promise)
    }

    /// Sends binary-formatted data to the connected client.
    ///
    ///     ws.onText { ws, string in
    ///         ws.send(binary: [0x68, 0x69])
    ///     }
    ///
    /// - parameters:
    ///     - data: `LosslessDataConvertible` to send as binary-formatted data to the client.
    ///     - promise: Optional `Promise` to complete when the send is finished.
    public func send(binary: LosslessDataConvertible, promise: Promise<Void>? = nil) {
        send(binary, opcode: .binary, promise: promise)
    }

    // MARK: Close

    /// `true` if the `WebSocket` has been closed.
    public private(set) var isClosed: Bool

    /// A `Future` that will be completed when the `WebSocket` closes.
    public var onClose: Future<Void> {
        return channel.closeFuture
    }

    /// Closes the `WebSocket`'s connection, disconnecting the client.
    public func close() {
        guard !isClosed else {
            return
        }
        channel.close(promise: nil)
    }

    // MARK: Private

    /// Private send that accepts a raw `WebSocketOpcode`.
    private func send(_ data: LosslessDataConvertible, opcode: WebSocketOpcode, promise: Promise<Void>?) {
        guard !isClosed else { return }
        let data = data.convertToData()
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.write(bytes: data)
        send(WebSocketFrame(fin: true, opcode: opcode, data: buffer), promise: promise)
    }

    /// Private send that accepts a raw `WebSocketFrame`.
    private func send(_ frame: WebSocketFrame, promise: Promise<Void>?) {
        channel.writeAndFlush(frame, promise: promise)
    }
}
