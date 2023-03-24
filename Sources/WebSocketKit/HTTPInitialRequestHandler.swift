import NIO
import NIOHTTP1

final class HTTPInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    let host: String
    let path: String
    let query: String?
    let decompression: Decompression.Configuration?
    let headers: HTTPHeaders
    let upgradePromise: EventLoopPromise<Void>

    init(host: String, path: String, query: String?, decompression: Decompression.Configuration?, headers: HTTPHeaders, upgradePromise: EventLoopPromise<Void>) {
        self.host = host
        self.path = path
        self.query = query
        self.decompression = decompression
        self.headers = headers
        self.upgradePromise = upgradePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = self.headers
        headers.add(name: "Host", value: self.host)

        var uri = self.path.hasPrefix("/") ? self.path : "/" + self.path
        if let query = self.query {
            uri += "?\(query)"
        }
        let requestHead = HTTPRequestHead(
            version: HTTPVersion(major: 1, minor: 1),
            method: .GET,
            uri: uri,
            headers: headers
        )
        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)

        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        let body = HTTPClientRequestPart.body(.byteBuffer(emptyBuffer))
        context.write(self.wrapOutboundOut(body), promise: nil)

        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let clientResponse = self.unwrapInboundIn(data)
        switch clientResponse {
        case .head(let responseHead):
            self.upgradePromise.fail(WebSocketClient.Error.invalidResponseStatus(responseHead))
        case .body: break
        case .end:
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.upgradePromise.fail(error)
        context.close(promise: nil)
    }
}
