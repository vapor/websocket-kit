import NIOCore
import NIOHTTP1

final class HTTPUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    let host: String
    let path: String
    let query: String?
    let headers: HTTPHeaders
    let upgradePromise: EventLoopPromise<Void>

    private var requestSent = false

    init(host: String, path: String, query: String?, headers: HTTPHeaders, upgradePromise: EventLoopPromise<Void>) {
        self.host = host
        self.path = path
        self.query = query
        self.headers = headers
        self.upgradePromise = upgradePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendRequest(context: context)
        context.fireChannelActive()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.sendRequest(context: context)
        }
    }

    private func sendRequest(context: ChannelHandlerContext) {
        if self.requestSent {
            // we might run into this handler twice, once in handlerAdded and once in channelActive.
            return
        }
        self.requestSent = true

        var headers = self.headers
        headers.add(name: "Host", value: self.host)

        var uri: String
        if self.path.hasPrefix("/") || self.path.hasPrefix("ws://") || self.path.hasPrefix("wss://") {
            uri = self.path
        } else {
            uri = "/" + self.path
        }

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
        // `NIOHTTPClientUpgradeHandler` should consume the first response in the success case,
        // any response we see here indicates a failure. Report the failure and tidy up at the end of the response.
        let clientResponse = self.unwrapInboundIn(data)
        switch clientResponse {
        case .head(let responseHead):
            let error = WebSocketClient.Error.invalidResponseStatus(responseHead)
            self.upgradePromise.fail(error)
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
