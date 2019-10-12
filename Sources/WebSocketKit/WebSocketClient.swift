import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOWebSocket
import NIOSSL


extension WebSocket {
    public static func connect(
        to url: String,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup
    ) -> EventLoopFuture<WebSocket> {
        guard let url = URL(string: url) else {
            return eventLoopGroup.next().makeFailedFuture(WebSocketClient.Error.invalidURL)
        }
        return self.connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup
        )
    }

    public static func connect(
        to url: URL,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup
    ) -> EventLoopFuture<WebSocket> {
        return self.connect(
            scheme: url.scheme ?? "ws",
            host: url.host ?? "localhost",
            port: url.port ?? 80,
            path: url.path,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup
        )
    }

    public static func connect(
        scheme: String = "ws",
        host: String,
        port: Int = 80,
        path: String = "/",
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup
    ) -> EventLoopFuture<WebSocket> {
        let client = WebSocketClient(eventLoopGroupProvider: .shared(eventLoopGroup), configuration: configuration)
        return client.connect(scheme: scheme, host: host, port: port, path: path, headers: headers).map { webSocket in
            webSocket.onClose.whenComplete { _ in
                try! client.syncShutdown()
            }
            return webSocket
        }
    }
}

public final class WebSocketClient {
    public enum Error: Swift.Error, LocalizedError {
        case invalidURL
        case invalidResponseStatus(HTTPResponseHead)
        case alreadyShutdown
        public var errorDescription: String? {
            return "\(self)"
        }
    }

    public enum EventLoopGroupProvider {
        case shared(EventLoopGroup)
        case createNew
    }

    public struct Configuration {
        public var tlsConfiguration: TLSConfiguration?
        public var maxFrameSize: Int

        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            maxFrameSize: Int = 1 << 14
        ) {
            self.tlsConfiguration = tlsConfiguration
            self.maxFrameSize = maxFrameSize
        }
    }

    let eventLoopGroupProvider: EventLoopGroupProvider
    let group: EventLoopGroup
    let configuration: Configuration
    let isShutdown = Atomic<Bool>(value: false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = .init()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.group = group
        case .createNew:
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        self.configuration = configuration
    }

    public func connect(
        scheme: String,
        host: String,
        port: Int,
        path: String = "/",
        headers: HTTPHeaders = [:]
    ) -> EventLoopFuture<WebSocket> {
        assert(["ws", "wss"].contains(scheme))
        let upgradePromise = self.group.next().makePromise(of: Void.self)
        let webSocketPromise = self.group.next().makePromise(of: WebSocket.self)
        let bootstrap = ClientBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let httpEncoder = HTTPRequestEncoder()
                let httpDecoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                let webSocketUpgrader = WebSocketClientUpgradeHandler(
                    configuration: self.configuration,
                    host: host,
                    path: path,
                    upgradePromise: upgradePromise
                ) { channel, response in
                    return channel.pipeline.removeHandler(httpEncoder).flatMap {
                        return channel.pipeline.removeHandler(httpDecoder)
                    }.flatMap {
                        return WebSocket.add(to: channel)
                    }.map { webSocket in
                        webSocketPromise.succeed(webSocket)
                    }
                }
                var handlers: [ChannelHandler] = []
                if scheme == "wss" {
                    let context = try! NIOSSLContext(
                        configuration: self.configuration.tlsConfiguration ?? .forClient()
                    )
                    let tlsHandler = try! NIOSSLClientHandler(context: context, serverHostname: host)
                    handlers.append(tlsHandler)
                }
                handlers += [httpEncoder, httpDecoder, webSocketUpgrader]
                return channel.pipeline.addHandlers(handlers)
            }

        let connect = bootstrap.connect(host: host, port: port)
        connect.cascadeFailure(to: upgradePromise)
        connect.cascadeFailure(to: webSocketPromise)
        upgradePromise.futureResult.cascadeFailure(to: webSocketPromise)
        return connect.flatMap { channel in
            return upgradePromise.futureResult.flatMap {
                return webSocketPromise.futureResult
            }
        }
    }


    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
            self.isShutdown.store(true)
            return
        case .createNew:
            if self.isShutdown.compareAndExchange(expected: false, desired: true) {
                try self.group.syncShutdownGracefully()
            } else {
                throw WebSocketClient.Error.alreadyShutdown
            }
        }
    }

    deinit {
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            assert(self.isShutdown.load(), "WebSocketClient not shutdown before deinit.")
        }
    }
}

private final class WebSocketClientUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let configuration: WebSocketClient.Configuration
    private let host: String
    private let path: String
    private let upgradePromise: EventLoopPromise<Void>
    private let upgradePipelineHandler: (Channel, HTTPResponseHead) -> EventLoopFuture<Void>

    private enum State {
        case ready
        case awaitingResponseEnd(HTTPResponseHead)
    }

    private var state: State

    init(
        configuration: WebSocketClient.Configuration,
        host: String,
        path: String,
        upgradePromise: EventLoopPromise<Void>,
        upgradePipelineHandler: @escaping (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
    ) {
        self.configuration = configuration
        self.host = host
        self.path = path
        self.upgradePromise = upgradePromise
        self.upgradePipelineHandler = upgradePipelineHandler
        self.state = .ready
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .head(let head):
            self.state = .awaitingResponseEnd(head)
        case .body:
            // ignore bodies
            break
        case .end:
            switch self.state {
            case .awaitingResponseEnd(let head):
                self.upgrade(context: context, upgradeResponse: head).cascade(to: self.upgradePromise)
            case .ready:
                fatalError("Invalid response state")
            }
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        let request = HTTPRequestHead(
            version: .init(major: 1, minor: 1),
            method: .GET,
            uri: self.path.hasPrefix("/") ? self.path : "/" + self.path,
            headers: self.buildUpgradeRequest()
        )
        context.write(self.wrapOutboundOut(.head(request)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }

    func buildUpgradeRequest() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "connection", value: "Upgrade")
        headers.add(name: "upgrade", value: "websocket")
        headers.add(name: "origin", value: "vapor/websocket")
        headers.add(name: "host", value: self.host)
        headers.add(name: "sec-websocket-version", value: "13")
        var bytes: [UInt8] = []
        for _ in 0..<16 {
            bytes.append(.random(in: .min ..< .max))
        }
        headers.add(name: "sec-websocket-key", value: Data(bytes).base64EncodedString())
        return headers
    }

    func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        guard upgradeResponse.status == .switchingProtocols else {
            return context.eventLoop.makeFailedFuture(
                WebSocketClient.Error.invalidResponseStatus(upgradeResponse)
            )
        }

        return context.channel.pipeline.addHandlers([
            WebSocketFrameEncoder(),
            ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: self.configuration.maxFrameSize))
        ]).flatMap {
            return context.pipeline.removeHandler(self)
        }.flatMap {
            return self.upgradePipelineHandler(context.channel, upgradeResponse)
        }
    }
}

extension HTTPRequestEncoder: RemovableChannelHandler { }
