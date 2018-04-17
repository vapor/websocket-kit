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

    /// If true, a close has been sent from this decoder.
    private var awaitingClose: Bool

    /// `WebSocket` to handle the incoming events.
    private var webSocket: WebSocket

    /// Creates a new `WebSocketEventDecoder`
    init(webSocket: WebSocket) {
        self.awaitingClose = false
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
        case .ping: pong(ctx: ctx, frame: frame)
        case .unknownControl, .unknownNonControl: closeOnError(ctx: ctx)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            webSocket.onTextCallback(webSocket, text)
        case .binary:
            var data = frame.unmaskedData
            let binary = data.readData(length: data.readableBytes) ?? Data()
            webSocket.onBinaryCallback(webSocket, binary)
        default:
            // We ignore all other frames.
            break
        }
    }

    /// See `ChannelInboundHandler`.
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        webSocket.onErrorCallback(webSocket, error)
    }

    /// Closes gracefully.
    private func receivedClose(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            ctx.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ctx.channel.allocator.buffer(capacity: 0)
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
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
        awaitingClose = true
    }
}
