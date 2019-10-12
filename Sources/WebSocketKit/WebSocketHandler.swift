import NIO
import NIOWebSocket

extension WebSocket {
    public static func client(on channel: Channel) -> EventLoopFuture<WebSocket> {
        return self.handle(on: channel, as: .client)
    }

    public static func server(on channel: Channel) -> EventLoopFuture<WebSocket> {
        return self.handle(on: channel, as: .server)
    }

    private static func handle(on channel: Channel, as type: PeerType) -> EventLoopFuture<WebSocket> {
        let webSocket = WebSocket(channel: channel, type: type)
        return channel.pipeline.addHandler(WebSocketHandler(webSocket: webSocket)).map { _ in
            webSocket
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

    /// See `ChannelInboundHandler`.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.webSocket.handle(incoming: frame)
    }
}
