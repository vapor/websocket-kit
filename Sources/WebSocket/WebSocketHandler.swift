extension ChannelPipeline {
    /// Adds the supplied `WebSocket` to this `ChannelPipeline`.
    internal func add(webSocket: WebSocket) -> Future<Void> {
        let handler = WebSocketHandler(webSocket: webSocket)
        return add(handler: handler)
    }
}

// MARK: Private

/// Decodes `WebSocketFrame`s, forwarding to a `WebSocket`.
private final class WebSocketHandler: ChannelInboundHandler {
    /// See `ChannelInboundHandler`.
    typealias InboundIn = WebSocketFrame

    /// See `ChannelInboundHandler`.
    typealias OutboundOut = WebSocketFrame

    /// `WebSocket` to handle the incoming events.
    private var webSocket: WebSocket

    private let frameSequence = WebSocketFrameSequence()

    /// Creates a new `WebSocketEventDecoder`
    init(webSocket: WebSocket) {
        self.webSocket = webSocket
    }

    /// See `ChannelInboundHandler`.
    func channelActive(ctx: ChannelHandlerContext) {
        // connected
    }

    /// See `ChannelInboundHandler`.
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose: receivedClose(ctx: ctx, frame: frame)
        case .ping:
            if !frame.fin {
                closeOnError(ctx: ctx) // control frames can't be fragmented it should be final
                return
            }

            pong(ctx: ctx, frame: frame)
        case .unknownControl, .unknownNonControl: closeOnError(ctx: ctx)
        case .text, .binary:
            if .InvalidOperation == frameSequence.addFirst(frame, for: frame.opcode) {
                closeOnError(ctx: ctx)
            }
        case .continuation:
            if .InvalidOperation == frameSequence.append(frame) {
                closeOnError(ctx: ctx)
            }
        default:
            // We ignore all other frames.
            break
        }

        if .InvalidOperation == frameSequence.process(frame, with: webSocket) {
            closeOnError(ctx: ctx)
        }
    }

    /// See `ChannelInboundHandler`.
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        webSocket.onErrorCallback(webSocket, error)
    }

    /// Closes gracefully.
    private func receivedClose(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        /// Parse the close frame.
        var data = frame.unmaskedData
        if let closeCode = data.readInteger(as: UInt16.self)
            .map(Int.init)
            .flatMap(WebSocketErrorCode.init(codeNumber:))
        {
            webSocket.onCloseCodeCallback(closeCode)
        }

        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if webSocket.isClosed {
            // Cool, we started the close and were waiting for the user. We're done.
            ctx.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
            _ = ctx.write(wrapOutboundOut(closeFrame)).always {
                _ = ctx.close(promise: nil)
            }
        }
    }

    /// Sends a pong frame in response to ping.
    private func pong(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        let maskingKey = frame.maskKey

        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        ctx.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }

    /// Closes the connection with error frame.
    private func closeOnError(ctx: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = ctx.channel.allocator.buffer(capacity: 2)
        let error = WebSocketErrorCode.protocolError
        data.write(webSocketErrorCode: error)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        _ = ctx.write(self.wrapOutboundOut(frame)).then {
            ctx.close(mode: .output)
        }
        webSocket.isClosed = true
    }
}

/*
https://tools.ietf.org/html/rfc6455#section-5
5.  Data Framing
   5.1.  Overview

   In the WebSocket Protocol, data is transmitted using a sequence of
   frames.  To avoid confusing network intermediaries (such as
   intercepting proxies) and for security reasons that are further
   discussed in Section 10.3, a client MUST mask all frames that it
   sends to the server (see Section 5.3 for further details).  (Note
   that masking is done whether or not the WebSocket Protocol is running
   over TLS.)  The server MUST close the connection upon receiving a
   frame that is not masked.  In this case, a server MAY send a Close
   frame with a status code of 1002 (protocol error) as defined in
   Section 7.4.1.  A server MUST NOT mask any frames that it sends to
   the client.  A client MUST close a connection if it detects a masked
   frame.  In this case, it MAY use the status code 1002 (protocol
   error) as defined in Section 7.4.1.  (These rules might be relaxed in
   a future specification.)

   The base framing protocol defines a frame type with an opcode, a
   payload length, and designated locations for "Extension data" and
   "Application data", which together define the "Payload data".
   Certain bits and opcodes are reserved for future expansion of the
   protocol.

   A data frame MAY be transmitted by either the client or the server at
   any time after opening handshake completion and before that endpoint
   has sent a Close frame (Section 5.5.1).
*/
private class WebSocketFrameSequence {
    enum WebSocketFrameSequenceResult {
        case InvalidOperation // need to close connection
        case Unknown // skip
        case Ok
    }

    private var textBuffer: String?
    private var dataBuffer: Data?
    private var prevFrameType: WebSocketOpcode?
    private let _lock = DispatchQueue(label: "WebSocketFrameSequence")

    private func reset() {
        textBuffer = nil
        prevFrameType = nil
        dataBuffer = nil
    }

    public func append(_ frame: WebSocketFrame) -> WebSocketFrameSequenceResult {
        return _lock.sync {
            guard let dataType = prevFrameType else {
                return .InvalidOperation
            }

            if dataType == .binary, dataBuffer != nil {
                var data = frame.unmaskedData
                dataBuffer?.append(data.readData(length: data.readableBytes) ?? Data())
            }
            else if dataType == .text, textBuffer != nil {
                var data = frame.unmaskedData
                textBuffer?.append(data.readString(length: data.readableBytes) ?? "")
            }
            else {
                return .InvalidOperation
            }

            return .Ok
        }
    }

    public func addFirst(_ frame: WebSocketFrame, for type: WebSocketOpcode) -> WebSocketFrameSequenceResult {
        return _lock.sync {
            if prevFrameType != nil || dataBuffer != nil || textBuffer != nil { // already contain frames
                return .InvalidOperation
            }

            if type == .binary {
                var data = frame.unmaskedData
                dataBuffer = data.readData(length: data.readableBytes) ?? Data()
            }
            else if type == .text {
                var data = frame.unmaskedData
                textBuffer = data.readString(length: data.readableBytes) ?? ""
            }
            else {
                return .InvalidOperation
            }

            prevFrameType = type
            return .Ok
        }
    }

    public func process(_ frame: WebSocketFrame, with webSocket: WebSocket) -> WebSocketFrameSequenceResult {
        return _lock.sync {
            guard let dataType = prevFrameType else {
                return .Unknown
            }

            if frame.fin {
                switch frame.opcode {
                case .text, .binary, // only for 1 len(where first frame is fin)
                     .continuation: // only for > 1 len(where latest frame is fin)
                    if dataType == .binary, let data = dataBuffer {
                        webSocket.onBinaryCallback(webSocket, data)
                    }
                    else if dataType == .text, let text = textBuffer {
                        webSocket.onTextCallback(webSocket, text)
                    }
                    else {
                        return .InvalidOperation
                    }
                    reset()

                    return .Ok
                default:
                    break
                }
            }

            return .Unknown
        }
    }
}