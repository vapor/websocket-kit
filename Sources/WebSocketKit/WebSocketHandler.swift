import NIO
import NIOWebSocket

extension WebSocket {
    public static func client(
        on channel: Channel,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.handle(on: channel, as: .client, decompression: nil, onUpgrade: onUpgrade)
    }
    
    public static func client(
        on channel: Channel,
        decompression: Decompression.Configuration?,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.handle(on: channel, as: .client, decompression: decompression, onUpgrade: onUpgrade)
    }

    public static func server(
        on channel: Channel,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.handle(on: channel, as: .server, decompression: nil, onUpgrade: onUpgrade)
    }

    private static func handle(
        on channel: Channel,
        as type: PeerType,
        decompression: Decompression.Configuration?,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        do {
            let webSocket = try WebSocket(channel: channel, type: type, decompression: decompression)
            return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket)).map { _ in
                onUpgrade(webSocket)
            }
        } catch {
            return channel.pipeline.eventLoop.makeFailedFuture(error)
        }
    }
}

extension WebSocketErrorCode {
    init(_ error: NIOWebSocketError) {
        switch error {
        case .invalidFrameLength:
            self = .messageTooLarge
        case .fragmentedControlFrame,
             .multiByteControlFrameLength:
            self = .protocolError
        }
    }
}

private final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private var webSocket: WebSocket

    init(webSocket: WebSocket) {
        self.webSocket = webSocket
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.webSocket.handle(incoming: frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let errorCode: WebSocketErrorCode
        if let error = error as? NIOWebSocketError {
            errorCode = WebSocketErrorCode(error)
        } else {
            errorCode = .unexpectedServerError
        }
        _ = webSocket.close(code: errorCode)

        // We always forward the error on to let others see it.
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let closedAbnormally = WebSocketErrorCode.unknown(1006)
        _ = webSocket.close(code: closedAbnormally)

        // We always forward the error on to let others see it.
        context.fireChannelInactive()
    }
}
