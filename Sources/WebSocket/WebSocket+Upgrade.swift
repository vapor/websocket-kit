extension WebSocket {
    /// Creates an `HTTPProtocolUpgrader` that will create instances of this class upon HTTP upgrade.
    public static func httpProtocolUpgrader(
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
            let req = HTTPRequest(
                method: head.method,
                url: head.uri,
                version: head.version,
                headers: head.headers
            )
            let encoder = WebSocketEventEncoder()
            let webSocket = WebSocket(eventHandler: encoder)
            let decoder = WebSocketEventDecoder(eventHandler: webSocket)
            return channel.pipeline.addHandlers(decoder, encoder, first: false).map {
                onUpgrade(webSocket, req)
            }
        })
    }
}

// MARK: Private

/// Encodes `WebSocketEvent`s to `WebSocketFrame`s.
private final class WebSocketEventEncoder: ChannelOutboundHandler, WebSocketEventHandler {
    /// See `ChannelOutboundHandler`.
    typealias OutboundIn = WebSocketFrame

    /// See `ChannelOutboundHandler`.
    typealias OutboundOut = WebSocketFrame


    /// Holds the current `ChannelHandlerContext`.
    private var currentCtx: ChannelHandlerContext? // fixme: better way to do this?

    /// See `ChannelOutboundHandler`.
    func handlerAdded(ctx: ChannelHandlerContext) {
        self.currentCtx = ctx
    }

    /// See `ChannelOutboundHandler`.
    func handlerRemoved(ctx: ChannelHandlerContext) {
        self.currentCtx = nil
    }

    /// See `WebSocketEventHandler`.
    func webSocketEvent(_ event: WebSocketEvent) {
        let ctx = currentCtx!
        switch event {
        case .binary(let data): send(count: data.count, opcode: .binary, ctx: ctx) { $0.write(bytes: data) }
        case .text(let str): send(count: str.count, opcode: .text, ctx: ctx) { $0.write(string: str) }
        case .close:
            send(count: 0, opcode: .connectionClose, ctx: ctx) { _ in  }
            ctx.close(promise: nil)
        default:
            // ignore all other events
            break
        }
    }

    /// Sends a bytebuffer according to supplied opcode.
    func send(count: Int, opcode: WebSocketOpcode, ctx: ChannelHandlerContext, bufferWriter: @escaping (inout ByteBuffer) -> ()) {
        guard ctx.channel.isActive else { return }
        var buffer = ctx.channel.allocator.buffer(capacity: count)
        bufferWriter(&buffer)
        let frame = WebSocketFrame(fin: true, opcode: opcode, data: buffer)
        ctx.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }
}

/// Decodes `WebSocketFrame`s, forwarding to a `WebSocketEventHandler`.
private final class WebSocketEventDecoder: ChannelInboundHandler {
    /// See `ChannelInboundHandler`.
    typealias InboundIn = WebSocketFrame

    /// See `ChannelInboundHandler`.
    typealias OutboundOut = WebSocketFrame

    /// If true, a close has been sent from this decoder.
    private var awaitingClose: Bool

    /// `WebSocketEventHandler` to handle the incoming events.
    private var eventHandler: WebSocketEventHandler

    /// Creates a new `WebSocketEventDecoder`
    init(eventHandler: WebSocketEventHandler) {
        self.awaitingClose = false
        self.eventHandler = eventHandler
    }

    /// See `ChannelInboundHandler`.
    func channelActive(ctx: ChannelHandlerContext) {
        eventHandler.webSocketEvent(.connect)
    }

    /// See `ChannelInboundHandler`.
    func channelInactive(ctx: ChannelHandlerContext) {
        eventHandler.webSocketEvent(.close)
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
            eventHandler.webSocketEvent(.text(text))
        case .binary:
            var data = frame.unmaskedData
            let binary = data.readData(length: data.readableBytes) ?? Data()
            eventHandler.webSocketEvent(.binary(binary))
        default:
            // We ignore all other frames.
            break
        }
    }

    /// See `ChannelInboundHandler`.
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        eventHandler.webSocketEvent(.error(error))
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
