import NIOCore
import NIOWebSocket

extension WebSocket {

    /// Stores configuration for a WebSocket client/server instance
    public struct Configuration: Sendable {
        /// Defends against small payloads in frame aggregation.
        /// See `NIOWebSocketFrameAggregator` for details.
        public var minNonFinalFragmentSize: Int
        /// Max number of fragments in an aggregated frame.
        /// See `NIOWebSocketFrameAggregator` for details.
        public var maxAccumulatedFrameCount: Int
        /// Maximum frame size after aggregation.
        /// See `NIOWebSocketFrameAggregator` for details.
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

    /// Sets up a channel to operate as a WebSocket client.
    /// - Parameters:
    ///   - channel: NIO channel which the client will use to communicate.
    ///   - onUpgrade: An escaping closure to be executed the channel is configured with the WebSocket handlers.
    /// - Returns: A future which completes when the WebSocket connection to the server is established.
    @preconcurrency
    public static func client(
        on channel: Channel,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .client, with: Configuration(), onUpgrade: onUpgrade)
    }

    /// Sets up a channel to operate as a WebSocket client.
    /// - Parameters:
    ///   - channel: NIO channel which the client/server will use to communicate.
    ///   - config: Configuration for the client channel handlers.
    ///   - onUpgrade: An escaping closure to be executed the channel is configured with the WebSocket handlers.
    /// - Returns: A future which completes when the WebSocket connection to the server is established.
    @preconcurrency
    public static func client(
        on channel: Channel,
        config: Configuration,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .client, with: config, onUpgrade: onUpgrade)
    }

    /// Sets up a channel to operate as a WebSocket server.
    /// - Parameters:
    ///   - channel: NIO channel which the server will use to communicate.
    ///   - onUpgrade: An escaping closure to be executed the channel is configured with the WebSocket handlers.
    /// - Returns: A future which completes when the WebSocket connection to the server is established.
    @preconcurrency
    public static func server(
        on channel: Channel,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .server, with: Configuration(), onUpgrade: onUpgrade)
    }

    /// Sets up a channel to operate as a WebSocket server.
    /// - Parameters:
    ///   - channel: NIO channel which the server will use to communicate.
    ///   - config: Configuration for the server channel handlers.
    ///   - onUpgrade: An escaping closure to be executed the channel is configured with the WebSocket handlers.
    /// - Returns: A future which completes when the WebSocket connection to the server is established.
    @preconcurrency
    public static func server(
        on channel: Channel,
        config: Configuration,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        return self.configure(on: channel, as: .server, with: config, onUpgrade: onUpgrade)
    }

    private static func configure(
        on channel: Channel,
        as type: PeerType,
        with config: Configuration,
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
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
