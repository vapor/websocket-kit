import XCTest
import Atomics
import NIO
import NIOExtras
import NIOHTTP1
import NIOSSL
import NIOWebSocket
@testable import WebSocketKit

extension ServerBootstrap {
    static func webSocket(
        on eventLoopGroup: EventLoopGroup,
        tls: Bool = false,
        onUpgrade: @escaping (HTTPRequestHead, WebSocket) -> ()
    ) -> ServerBootstrap {
        return ServerBootstrap(group: eventLoopGroup).childChannelInitializer { channel in
            if tls {
                let (cert, key) = generateSelfSignedCert()
                let configuration = TLSConfiguration.makeServerConfiguration(
                    certificateChain: [.certificate(cert)],
                    privateKey: .privateKey(key)
                )
                let sslContext = try! NIOSSLContext(configuration: configuration)
                let handler = NIOSSLServerHandler(context: sslContext)
                _ = channel.pipeline.addHandler(handler)
            }
            let webSocket = NIOWebSocketServerUpgrader(
                shouldUpgrade: { channel, req in
                    return channel.eventLoop.makeSucceededFuture([:])
                },
                upgradePipelineHandler: { channel, req in
                    return WebSocket.server(on: channel) { ws in
                        onUpgrade(req, ws)
                    }
                }
            )
            return channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (
                    upgraders: [webSocket],
                    completionHandler: { ctx in
                        // complete
                    }
                )
            )
        }
    }
}

internal final class WebsocketBin {
    enum BindTarget {
        case unixDomainSocket(String)
        case localhostIPv4RandomPort
        case localhostIPv6RandomPort
    }

    enum Mode {
        // refuses all connections
        case refuse
        // supports http1.1 connections only, which can be either plain text or encrypted
        case http1_1(ssl: Bool = false)
    }

    enum Proxy {
        case none
        case simulate(config: ProxyConfig, authorization: String?)
    }

    struct ProxyConfig {
        var tls: Bool
        let headVerification: (ChannelHandlerContext, HTTPRequestHead) -> Void
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    var port: Int {
        return Int(self.serverChannel.localAddress!.port!)
    }

    private let mode: Mode
    private let sslContext: NIOSSLContext?
    private var serverChannel: Channel!
    private let isShutdown = ManagedAtomic(false)

    init(
        _ mode: Mode = .http1_1(ssl: false),
        proxy: Proxy = .none,
        bindTarget: BindTarget = .localhostIPv4RandomPort,
        sslContext: NIOSSLContext?,
        onUpgrade: @escaping (HTTPRequestHead, WebSocket) -> ()
    ) {
        self.mode = mode
        self.sslContext = sslContext

        let socketAddress: SocketAddress
        switch bindTarget {
        case .localhostIPv4RandomPort:
            socketAddress = try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
        case .localhostIPv6RandomPort:
            socketAddress = try! SocketAddress(ipAddress: "::1", port: 0)
        case .unixDomainSocket(let path):
            socketAddress = try! SocketAddress(unixDomainSocketPath: path)
        }

        self.serverChannel = try! ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                do {

                    if case .refuse = mode {
                        throw HTTPBinError.refusedConnection
                    }

                    let webSocket = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { channel, req in
                            return channel.eventLoop.makeSucceededFuture([:])
                        },
                        upgradePipelineHandler: { channel, req in
                            return WebSocket.server(on: channel) { ws in
                                onUpgrade(req, ws)
                            }
                        }
                    )

                    // if we need to simulate a proxy, we need to add those handlers first
                    if case .simulate(config: let config, authorization: let expectedAuthorization) = proxy {
                        if config.tls {
                            try self.syncAddTLSHTTPProxyHandlers(
                                to: channel,
                                proxyConfig: config,
                                expectedAuthorization: expectedAuthorization,
                                upgraders: [webSocket]
                            )
                        } else {
                            try self.syncAddHTTPProxyHandlers(
                                to: channel,
                                proxyConfig: config,
                                expectedAuthorization: expectedAuthorization,
                                upgraders: [webSocket]
                            )
                        }
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }

                    // if a connection has been established, we need to negotiate TLS before
                    // anything else. Depending on the negotiation, the HTTPHandlers will be added.
                    if let sslContext = self.sslContext {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    }

                    // if neither HTTP Proxy nor TLS are wanted, we can add HTTP1 handlers directly
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withPipeliningAssistance: true,
                        withServerUpgrade: (
                            upgraders: [webSocket],
                            completionHandler: { ctx in
                                // complete
                            }
                        ),
                        withErrorHandling: true
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.bind(to: socketAddress).wait()
    }


    // In the TLS case we must set up the 'proxy' and the 'server' handlers sequentially
    // rather than re-using parts because the requestDecoder stops parsing after a CONNECT request
    private func syncAddTLSHTTPProxyHandlers(
        to channel: Channel,
        proxyConfig: ProxyConfig,
        expectedAuthorization: String?,
        upgraders: [HTTPServerProtocolUpgrader]
    ) throws {
        let sync = channel.pipeline.syncOperations
        let promise = channel.eventLoop.makePromise(of: Void.self)

        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let proxySimulator = HTTPProxySimulator(promise: promise, config: proxyConfig, expectedAuthorization: expectedAuthorization)

        try sync.addHandler(responseEncoder)
        try sync.addHandler(requestDecoder)

        try sync.addHandler(proxySimulator)

        promise.futureResult.flatMap { _ in
            channel.pipeline.removeHandler(proxySimulator)
        }.flatMap { _ in
            channel.pipeline.removeHandler(responseEncoder)
        }.flatMap { _ in
            channel.pipeline.removeHandler(requestDecoder)
        }.whenComplete { result in
            switch result {
            case .failure:
                channel.close(mode: .all, promise: nil)
            case .success:
                self.httpProxyEstablished(channel, upgraders: upgraders)
                break
            }
        }
    }


    // In the plain-text case we must set up the 'proxy' and the 'server' handlers simultaneously
    // so that the combined proxy/upgrade request can be processed by the separate proxy and upgrade handlers
    private func syncAddHTTPProxyHandlers(
        to channel: Channel,
        proxyConfig: ProxyConfig,
        expectedAuthorization: String?,
        upgraders: [HTTPServerProtocolUpgrader]
    ) throws {
        let sync = channel.pipeline.syncOperations
        let promise = channel.eventLoop.makePromise(of: Void.self)

        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let proxySimulator = HTTPProxySimulator(promise: promise, config: proxyConfig, expectedAuthorization: expectedAuthorization)

        let serverPipelineHandler = HTTPServerPipelineHandler()
        let serverProtocolErrorHandler = HTTPServerProtocolErrorHandler()

        let extraHTTPHandlers: [RemovableChannelHandler] = [
            requestDecoder,
            serverPipelineHandler,
            serverProtocolErrorHandler
        ]

        try sync.addHandler(responseEncoder)
        try sync.addHandler(requestDecoder)

        try sync.addHandler(proxySimulator)

        try sync.addHandler(serverPipelineHandler)
        try sync.addHandler(serverProtocolErrorHandler)


        let upgrader = HTTPServerUpgradeHandler(upgraders: upgraders,
                                                httpEncoder: responseEncoder,
                                                extraHTTPHandlers: extraHTTPHandlers,
                                                upgradeCompletionHandler: { ctx in
            // complete
        })


        try sync.addHandler(upgrader)

        promise.futureResult.flatMap { () -> EventLoopFuture<Void> in
            channel.pipeline.removeHandler(proxySimulator)
        }.whenComplete { result in
            switch result {
            case .failure:
                channel.close(mode: .all, promise: nil)
            case .success:
                break
            }
        }
    }

    private func httpProxyEstablished(_ channel: Channel, upgraders: [HTTPServerProtocolUpgrader]) {
        do {
            // if a connection has been established, we need to negotiate TLS before
            // anything else. Depending on the negotiation, the HTTPHandlers will be added.
            if let sslContext = self.sslContext {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
            }

            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withServerUpgrade: (
                    upgraders: upgraders,
                    completionHandler: { ctx in
                        // complete
                    }
                ),
                withErrorHandling: true
            )
        } catch {
            // in case of an while modifying the pipeline we should close the connection
            channel.close(mode: .all, promise: nil)
        }
    }

    func shutdown() throws {
        self.isShutdown.store(true, ordering: .relaxed)
        try self.group.syncShutdownGracefully()
    }
}

enum HTTPBinError: Error {
    case refusedConnection
    case invalidProxyRequest
}

final class HTTPProxySimulator: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart


    // the promise to succeed, once the proxy connection is setup
    let promise: EventLoopPromise<Void>
    let config: WebsocketBin.ProxyConfig
    let expectedAuthorization: String?

    var head: HTTPResponseHead

    init(promise: EventLoopPromise<Void>, config: WebsocketBin.ProxyConfig, expectedAuthorization: String?) {
        self.promise = promise
        self.config = config
        self.expectedAuthorization = expectedAuthorization
        self.head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: .init([("Content-Length", "0")]))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        switch request {
        case .head(let head):
            if self.config.tls {
                guard head.method == .CONNECT else {
                    self.head.status = .badRequest
                    return
                }
            } else {
                guard head.method == .GET else {
                    self.head.status = .badRequest
                    return
                }
            }

            self.config.headVerification(context, head)

            if let expectedAuthorization = self.expectedAuthorization {
                guard let authorization = head.headers["proxy-authorization"].first,
                      expectedAuthorization == authorization else {
                    self.head.status = .proxyAuthenticationRequired
                    return
                }
            }
            if !self.config.tls {
                context.fireChannelRead(data)
            }

        case .body:
            ()
        case .end:
            if self.self.config.tls {
                context.write(self.wrapOutboundOut(.head(self.head)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
            if self.head.status == .ok {
                if !self.config.tls {
                    context.fireChannelRead(data)
                }
                self.promise.succeed(())
            } else {
                self.promise.fail(HTTPBinError.invalidProxyRequest)
            }
        }
    }
}
