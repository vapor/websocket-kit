import Foundation

extension WebSocket {
    /// Creates an `HTTPProtocolUpgrader` that will create instances of this class upon HTTP upgrade.
    public static func httpProtocolUpgrader(
        shouldUpgrade: @escaping (HTTPRequest) -> (HTTPHeaders?),
        onUpgrade: @escaping (WebSocket, HTTPRequest) -> ()
    ) -> HTTPProtocolUpgrader {
        return WebSocketUpgrader(shouldUpgrade: { head in
            let req = HTTPRequest(
                method: head.method,
                url: URL(string: head.uri)!,
                version: head.version,
                headers: head.headers,
                body: .init()
            )
            return shouldUpgrade(req)
        }, upgradePipelineHandler: { channel, head in
            let req = HTTPRequest(
                method: head.method,
                url: URL(string: head.uri)!,
                version: head.version,
                headers: head.headers,
                body: .init()
            )
            let handler = WebsocketHandler()
            let websocket = WebSocket(handler: handler)
            handler.onConnect = {
                onUpgrade(websocket, req)
            }
            return channel.pipeline.add(handler: handler)
        })
    }

}

/// NIO channel pipeline handler for web sockets.
internal final class WebsocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private var awaitingClose: Bool = false

    internal var onText: ((String) -> ())?
    internal var onData: ((Data) -> ())?
    internal var onClose: (() -> ())?
    internal var onError: ((Error) -> ())?
    internal var onConnect: (() -> ())?

    private var currentCtx: ChannelHandlerContext?

    public func handlerAdded(ctx: ChannelHandlerContext) {
        // do something here?
        self.currentCtx = ctx
        onConnect?()
        onConnect = nil
    }

    func handlerRemoved(ctx: ChannelHandlerContext) {
        close()
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            self.receivedClose(ctx: ctx, frame: frame)
        case .ping:
            self.pong(ctx: ctx, frame: frame)
        case .unknownControl, .unknownNonControl:
            self.closeOnError(ctx: ctx)
        case .text:
            if let onText = self.onText {
                var data = frame.unmaskedData
                let string = data.readString(length: data.readableBytes)!
                onText(string)
            }
        case .binary:
            if let onData = self.onData {
                var data = frame.unmaskedData
                let string = data.readData(length: data.readableBytes)!
                onData(string)
            }
        default:
            // We ignore all other frames.
            break
        }
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }

    func close() {
        onClose?()
        onClose = nil
        onData = nil
        onText = nil
        onError = nil
        currentCtx?.close(promise: nil)
        currentCtx = nil
    }

    func send(count: Int, opcode: WebSocketOpcode, bufferWriter: @escaping (inout ByteBuffer) -> ()) {
        let ctx = currentCtx!
        ctx.eventLoop.execute {
            guard ctx.channel.isActive else { return }
            // We can't send if we sent a close message.
            guard !self.awaitingClose else { return }
            var buffer = ctx.channel.allocator.buffer(capacity: count)
            bufferWriter(&buffer)
            let frame = WebSocketFrame(fin: true, opcode: opcode, data: buffer)
            ctx.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
        }
    }

    private func receivedClose(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            close()
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ctx.channel.allocator.buffer(capacity: 0)
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            _ = ctx.write(self.wrapOutboundOut(closeFrame)).map { () in
                self.close()
            }
        }
    }

    private func pong(ctx: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        let maskingKey = frame.maskKey

        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        ctx.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        onError?(error)
    }

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
