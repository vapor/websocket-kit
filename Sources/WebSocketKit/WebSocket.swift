import NIOCore
import NIOWebSocket
import NIOHTTP1
import NIOSSL
import Foundation
import NIOFoundationCompat
import NIOConcurrencyHelpers

public final class WebSocket: Sendable {
    enum PeerType: Sendable {
        case server
        case client
    }

    public var eventLoop: EventLoop {
        return channel.eventLoop
    }

    public var isClosed: Bool {
        !self.channel.isActive
    }
    public var closeCode: WebSocketErrorCode? {
        _closeCode.withLockedValue { $0 }
    }
    
    private let _closeCode: NIOLockedValueBox<WebSocketErrorCode?>

    public var onClose: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    @usableFromInline
    /* private but @usableFromInline */
    internal let channel: Channel
    private let onTextCallback: NIOLoopBoundBox<@Sendable (WebSocket, String) -> ()>
    private let onBinaryCallback: NIOLoopBoundBox<@Sendable (WebSocket, ByteBuffer) -> ()>
    private let onPongCallback: NIOLoopBoundBox<@Sendable (WebSocket, ByteBuffer) -> ()>
    private let onPingCallback: NIOLoopBoundBox<@Sendable (WebSocket, ByteBuffer) -> ()>
    private let type: PeerType
    private let waitingForPong: NIOLockedValueBox<Bool>
    private let waitingForClose: NIOLockedValueBox<Bool>
    private let scheduledTimeoutTask: NIOLockedValueBox<Scheduled<Void>?>
    private let frameSequence: NIOLockedValueBox<WebSocketFrameSequence?>
    private let _pingInterval: NIOLockedValueBox<TimeAmount?>

    init(channel: Channel, type: PeerType) {
        self.channel = channel
        self.type = type
        self.onTextCallback = .init({ _, _ in }, eventLoop: channel.eventLoop)
        self.onBinaryCallback = .init({ _, _ in }, eventLoop: channel.eventLoop)
        self.onPongCallback = .init({ _, _ in }, eventLoop: channel.eventLoop)
        self.onPingCallback = .init({ _, _ in }, eventLoop: channel.eventLoop)
        self.waitingForPong = .init(false)
        self.waitingForClose = .init(false)
        self.scheduledTimeoutTask = .init(nil)
        self._closeCode = .init(nil)
        self.frameSequence = .init(nil)
        self._pingInterval = .init(nil)
    }

    @preconcurrency public func onText(_ callback: @Sendable @escaping (WebSocket, String) -> ()) {
        self.onTextCallback.value = callback
    }

    @preconcurrency public func onBinary(_ callback: @Sendable @escaping (WebSocket, ByteBuffer) -> ()) {
        self.onBinaryCallback.value = callback
    }
    
    public func onPong(_ callback: @Sendable @escaping (WebSocket, ByteBuffer) -> ()) {
        self.onPongCallback.value = callback
    }
    
    @available(*, deprecated, message: "Please use `onPong { socket, data in /* … */ }` with the additional `data` parameter.")
    @preconcurrency public func onPong(_ callback: @Sendable @escaping (WebSocket) -> ()) {
        self.onPongCallback.value = { ws, _ in callback(ws) }
    }

    public func onPing(_ callback: @Sendable @escaping (WebSocket, ByteBuffer) -> ()) {
        self.onPingCallback.value = callback
    }
    
    @available(*, deprecated, message: "Please use `onPing { socket, data in /* … */ }` with the additional `data` parameter.")
    @preconcurrency public func onPing(_ callback: @Sendable @escaping (WebSocket) -> ()) {
        self.onPingCallback.value = { ws, _ in callback(ws) }
    }

    /// If set, this will trigger automatic pings on the connection. If ping is not answered before
    /// the next ping is sent, then the WebSocket will be presumed inactive and will be closed
    /// automatically.
    /// These pings can also be used to keep the WebSocket alive if there is some other timeout
    /// mechanism shutting down inactive connections, such as a Load Balancer deployed in
    /// front of the server.
    public var pingInterval: TimeAmount? {
        get {
            return _pingInterval.withLockedValue { $0 }
        }
        set {
            _pingInterval.withLockedValue { $0 = newValue }
            if newValue != nil {
                if scheduledTimeoutTask.withLockedValue({ $0 == nil }) {
                    waitingForPong.withLockedValue { $0 = false }
                    self.pingAndScheduleNextTimeoutTask()
                }
            } else {
                scheduledTimeoutTask.withLockedValue { $0?.cancel() }
            }
        }
    }

    @inlinable
    public func send<S>(_ text: S, promise: EventLoopPromise<Void>? = nil)
        where S: Collection, S.Element == Character
    {
        let string = String(text)
        let buffer = channel.allocator.buffer(string: string)
        self.send(buffer, opcode: .text, fin: true, promise: promise)

    }

    public func send(_ binary: some DataProtocol, promise: EventLoopPromise<Void>? = nil) {
        self.send(raw: binary, opcode: .binary, fin: true, promise: promise)
    }

    public func sendPing(promise: EventLoopPromise<Void>? = nil) {
        sendPing(Data(), promise: promise)
    }

    public func sendPing(_ data: Data, promise: EventLoopPromise<Void>? = nil) {
        self.send(
            raw: data,
            opcode: .ping,
            fin: true,
            promise: promise
        )
    }

    @inlinable
    public func send<Data>(
        raw data: Data,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    )
        where Data: DataProtocol
    {
        if let byteBufferView = data as? ByteBufferView {
            // optimisation: converting from `ByteBufferView` to `ByteBuffer` doesn't allocate or copy any data
            send(ByteBuffer(byteBufferView), opcode: opcode, fin: fin, promise: promise)
        } else {
            let buffer = channel.allocator.buffer(bytes: data)
            send(buffer, opcode: opcode, fin: fin, promise: promise)
        }
    }

    /// Send the provided data in a WebSocket frame.
    /// - Parameters:
    ///   - data: Data to be sent.
    ///   - opcode: Frame opcode.
    ///   - fin: The value of the fin bit.
    ///   - promise: A promise to be completed when the write is complete.
    public func send(
        _ data: ByteBuffer,
        opcode: WebSocketOpcode = .binary,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        let frame = WebSocketFrame(
            fin: fin,
            opcode: opcode,
            maskKey: self.makeMaskKey(),
            data: data
        )
        self.channel.writeAndFlush(frame, promise: promise)
    }

    public func close(code: WebSocketErrorCode = .goingAway) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.close(code: code, promise: promise)
        return promise.futureResult
    }

    public func close(
        code: WebSocketErrorCode = .goingAway,
        promise: EventLoopPromise<Void>?
    ) {
        guard !self.isClosed else {
            promise?.succeed(())
            return
        }
        guard !self.waitingForClose.withLockedValue({ $0 }) else {
            promise?.succeed(())
            return
        }
        self.waitingForClose.withLockedValue { $0 = true }
        self._closeCode.withLockedValue { $0 = code }

        let codeAsInt = UInt16(webSocketErrorCode: code)
        let codeToSend: WebSocketErrorCode
        if codeAsInt == 1005 || codeAsInt == 1006 {
            /// Code 1005 and 1006 are used to report errors to the application, but must never be sent over
            /// the wire (per https://tools.ietf.org/html/rfc6455#section-7.4)
            codeToSend = .normalClosure
        } else {
            codeToSend = code
        }

        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)

        self.send(raw: buffer.readableBytesView, opcode: .connectionClose, fin: true, promise: promise)
    }

    func makeMaskKey() -> WebSocketMaskingKey? {
        switch type {
        case .client:
            /// See https://github.com/apple/swift/issues/66099
            var generator = SystemRandomNumberGenerator()
            return WebSocketMaskingKey.random(using: &generator)
        case .server:
            return nil
        }
    }

    func handle(incoming frame: WebSocketFrame) {
        switch frame.opcode {
        case .connectionClose:
            if self.waitingForClose.withLockedValue({ $0 }) {
                // peer confirmed close, time to close channel
                self.channel.close(mode: .all, promise: nil)
            } else {
                // peer asking for close, confirm and close output side channel
                let promise = self.eventLoop.makePromise(of: Void.self)
                var data = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    data.webSocketUnmask(maskingKey)
                }
                self.close(
                    code: data.readWebSocketErrorCode() ?? .unknown(1005),
                    promise: promise
                )
                promise.futureResult.whenComplete { _ in
                    self.channel.close(mode: .all, promise: nil)
                }
            }
        case .ping:
            if frame.fin {
                var frameData = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    frameData.webSocketUnmask(maskingKey)
                }
                self.onPingCallback.value(self, ByteBuffer(buffer: frameData))
                self.send(
                    raw: frameData.readableBytesView,
                    opcode: .pong,
                    fin: true,
                    promise: nil
                )
            } else {
                self.close(code: .protocolError, promise: nil)
            }
        case .pong:
            if frame.fin {
                var frameData = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    frameData.webSocketUnmask(maskingKey)
                }
                self.waitingForPong.withLockedValue { $0 = false }
                self.onPongCallback.value(self, ByteBuffer(buffer: frameData))
            } else {
                self.close(code: .protocolError, promise: nil)
            }
        case .text, .binary:
            // create a new frame sequence or use existing
            self.frameSequence.withLockedValue { currentFrameSequence in
                var frameSequence = currentFrameSequence ?? .init(type: frame.opcode)
                // append this frame and update the sequence
                frameSequence.append(frame)
                currentFrameSequence = frameSequence
            }
        case .continuation:
            /// continuations are filtered by ``NIOWebSocketFrameAggregator``
            preconditionFailure("We will never receive a continuation frame")
        default:
            // We ignore all other frames.
            break
        }

        // if this frame was final and we have a non-nil frame sequence,
        // output it to the websocket and clear storage
        self.frameSequence.withLockedValue { currentFrameSequence in
            if let frameSequence = currentFrameSequence, frame.fin {
                switch frameSequence.type {
                case .binary:
                    self.onBinaryCallback.value(self, frameSequence.binaryBuffer)
                case .text:
                    self.onTextCallback.value(self, frameSequence.textBuffer)
                case .ping, .pong:
                    assertionFailure("Control frames never have a frameSequence")
                default: break
                }
                currentFrameSequence = nil
            }
        }
    }

    @Sendable
    private func pingAndScheduleNextTimeoutTask() {
        guard channel.isActive, let pingInterval = pingInterval else {
            return
        }

        if waitingForPong.withLockedValue({ $0 }) {
            // We never received a pong from our last ping, so the connection has timed out
            let promise = self.eventLoop.makePromise(of: Void.self)
            self.close(code: .unknown(1006), promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocket is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                self.channel.close(mode: .all, promise: nil)
            }
        } else {
            self.sendPing()
            self.waitingForPong.withLockedValue { $0 = true }
            self.scheduledTimeoutTask.withLockedValue {
                $0 = self.eventLoop.scheduleTask(
                    deadline: .now() + pingInterval,
                    self.pingAndScheduleNextTimeoutTask
                )
            }
        }
    }

    deinit {
        assert(self.isClosed, "WebSocket was not closed before deinit.")
    }
}

private struct WebSocketFrameSequence: Sendable {
    var binaryBuffer: ByteBuffer
    var textBuffer: String
    let type: WebSocketOpcode
    let lock: NIOLock

    init(type: WebSocketOpcode) {
        self.binaryBuffer = ByteBufferAllocator().buffer(capacity: 0)
        self.textBuffer = .init()
        self.type = type
        self.lock = .init()
    }

    mutating func append(_ frame: WebSocketFrame) {
        self.lock.withLockVoid {
            var data = frame.unmaskedData
            switch type {
            case .binary:
                self.binaryBuffer.writeBuffer(&data)
            case .text:
                if let string = data.readString(length: data.readableBytes) {
                    self.textBuffer += string
                }
            default: break
            }
        }
    }
}
