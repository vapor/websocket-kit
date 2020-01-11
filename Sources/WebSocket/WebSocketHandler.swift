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

    /// Current frame sequence.
    private var frameSequence: WebSocketFrameSequence?

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
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose: receivedClose(ctx: ctx, frame: frame)
        case .ping:
            if !frame.fin {
                closeOnError(ctx: ctx) // control frames can't be fragmented it should be final
            } else {
                pong(ctx: ctx, frame: frame)
            }
        case .pong:
            webSocket.onPongCallback(webSocket, frameSequence?.dataBuffer)
        case .unknownControl, .unknownNonControl: closeOnError(ctx: ctx)
        case .text, .binary:
            // create a new frame sequence or use existing
            var frameSequence: WebSocketFrameSequence
            if let existing = self.frameSequence {
                frameSequence = existing
            } else {
                frameSequence = WebSocketFrameSequence(type: frame.opcode)
            }
            // append this frame and update the sequence
            frameSequence.append(frame)
            self.frameSequence = frameSequence
        case .continuation:
            // we must have an existing sequence
            if var frameSequence = self.frameSequence {
                // append this frame and update
                frameSequence.append(frame)
                self.frameSequence = frameSequence
            } else {
                closeOnError(ctx: ctx)
            }
        }
        
        // if this frame was final and we have a non-nil frame sequence,
        // output it to the websocket and clear storage
        if let frameSequence = self.frameSequence, frame.fin {
            switch frameSequence.type {
            case .binary: webSocket.onBinaryCallback(webSocket, frameSequence.dataBuffer)
            case .text: webSocket.onTextCallback(webSocket, frameSequence.textBuffer)
            default: break
            }
            self.frameSequence = nil
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
            _ = ctx.writeAndFlush(wrapOutboundOut(closeFrame)).always {
                _ = ctx.close(promise: nil)
            }
        }
    }

    /// Sends a pong frame in response to ping.
    private func pong(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        let pongFrame = WebSocketFrame(
            fin: true,
            opcode: .pong,
            maskKey: webSocket.mode.makeMaskKey(),
            data: frame.data
        )
        ctx.writeAndFlush(self.wrapOutboundOut(pongFrame), promise: nil)
    }

    /// Closes the connection with error frame.
    private func closeOnError(ctx: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = ctx.channel.allocator.buffer(capacity: 2)
        let error = WebSocketErrorCode.protocolError
        data.write(webSocketErrorCode: error)
        let frame = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                maskKey: webSocket.mode.makeMaskKey(),
                data: data
        )

        _ = ctx.writeAndFlush(self.wrapOutboundOut(frame)).then {
            ctx.close(mode: .output)
        }
        webSocket.isClosed = true
    }
}
