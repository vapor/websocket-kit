import NIO
import NIOWebSocket

extension WebSocket {

    public struct Configuration {
        // continuation aggregation configuration
        public var minNonFinalFragmentSize: Int
        public var maxAccumulatedFrameCount: Int
        public var maxAccumulatedFrameSize: Int

        public init() {
            self.minNonFinalFragmentSize = 0
            self.maxAccumulatedFrameCount = Int.max
            self.maxAccumulatedFrameSize = Int.max
        }

        internal init(clientConfig: WebSocketClient.Configuration) {
            self.minNonFinalFragmentSize = clientConfig.minNonFinalFragmentSize
            self.maxAccumulatedFrameCount = clientConfig.maxAccumulatedFrameCount
            self.maxAccumulatedFrameSize = clientConfig.maxAccumulatedFrameSize
        }
    }

    public static func client(
        on channel: Channel,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .client, with: Configuration(), onUpgrade: onUpgrade)
    }

    public static func client(
        on channel: Channel,
        config: Configuration,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .client, with: config, onUpgrade: onUpgrade)
    }

    public static func server(
        on channel: Channel,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .server, with: Configuration(), onUpgrade: onUpgrade)
    }

    public static func server(
        on channel: Channel,
        config: Configuration,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .server, with: config, onUpgrade: onUpgrade)
    }

    private static func configure(
        on channel: Channel,
        as type: PeerType,
        with config: Configuration,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        let webSocket = WebSocket(channel: channel, type: type)

        return channel.pipeline.addHandlers([
            NIOWebSocketFrameAggregator(
                minNonFinalFragmentSize: config.minNonFinalFragmentSize,
                maxAccumulatedFrameCount: config.maxAccumulatedFrameCount,
                maxAccumulatedFrameSize: config.maxAccumulatedFrameSize
            ),
            WebSocketHandler(webSocket: webSocket)
        ]).map { _ in
            onUpgrade(webSocket)
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
