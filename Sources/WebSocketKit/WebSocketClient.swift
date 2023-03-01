import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOExtras
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOTransportServices
import Atomics

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

        /// Defends against small payloads in frame aggregation.
        /// See `NIOWebSocketFrameAggregator` for details.
        public var minNonFinalFragmentSize: Int
        /// Max number of fragments in an aggregated frame.
        /// See `NIOWebSocketFrameAggregator` for details.
        public var maxAccumulatedFrameCount: Int
        /// Maximum frame size after aggregation.
        /// See `NIOWebSocketFrameAggregator` for details.
        public var maxAccumulatedFrameSize: Int

        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            maxFrameSize: Int = 1 << 14
        ) {
            self.tlsConfiguration = tlsConfiguration
            self.maxFrameSize = maxFrameSize
            self.minNonFinalFragmentSize = 0
            self.maxAccumulatedFrameCount = Int.max
            self.maxAccumulatedFrameSize = Int.max
        }
    }

    let eventLoopGroupProvider: EventLoopGroupProvider
    let group: EventLoopGroup
    let configuration: Configuration
    let isShutdown = ManagedAtomic(false)

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
        query: String? = nil,
        headers: HTTPHeaders = [:],
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        self.connect(scheme: scheme, host: host, port: port, path: path, query: query, headers: headers, proxy: nil, onUpgrade: onUpgrade)
    }

    public func connect(
        scheme: String,
        host: String,
        port: Int,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        proxy: String?,
        proxyPort: Int? = nil,
        proxyHeaders: HTTPHeaders = [:],
        proxyConnectDeadline: NIODeadline = NIODeadline.distantFuture,
        onUpgrade: @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        assert(["ws", "wss"].contains(scheme))
        let upgradePromise = self.group.next().makePromise(of: Void.self)
        let bootstrap = WebSocketClient.makeBootstrap(on: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel -> EventLoopFuture<Void> in

                let uri: String
                var upgradeRequestHeaders = headers
                if proxy == nil {
                    uri = path
                } else {
                    let relativePath = path.hasPrefix("/") ? path : "/" + path
                    let port = proxyPort.map { ":\($0)" } ?? ""
                    uri = "\(scheme)://\(host)\(relativePath)\(port)"

                    if scheme == "ws" {
                        upgradeRequestHeaders.add(contentsOf: proxyHeaders)
                    }
                }

                let httpUpgradeRequestHandler = HTTPUpgradeRequestHandler(
                    host: host,
                    path: uri,
                    query: query,
                    headers: upgradeRequestHeaders,
                    upgradePromise: upgradePromise
                )

                let websocketUpgrader = NIOWebSocketClientUpgrader(
                    maxFrameSize: self.configuration.maxFrameSize,
                    automaticErrorHandling: true,
                    upgradePipelineHandler: { channel, req in
                        return WebSocket.client(on: channel, config: .init(clientConfig: self.configuration), onUpgrade: onUpgrade)
                    }
                )

                let config: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [websocketUpgrader],
                    completionHandler: { context in
                        upgradePromise.succeed(())
                        channel.pipeline.removeHandler(httpUpgradeRequestHandler, promise: nil)
                    }
                )

                if proxy == nil || scheme == "ws" {
                    if scheme == "wss" {
                        do {
                            let tlsHandler = try self.makeTLSHandler(tlsConfiguration: self.configuration.tlsConfiguration, host: host)
                            // The sync methods here are safe because we're on the channel event loop
                            // due to the promise originating on the event loop of the channel.
                            try channel.pipeline.syncOperations.addHandler(tlsHandler)
                        } catch {
                            return channel.pipeline.close(mode: .all)
                        }
                    }

                    return channel.pipeline.addHTTPClientHandlers(
                        leftOverBytesStrategy: .forwardBytes,
                        withClientUpgrade: config
                    ).flatMap {
                        channel.pipeline.addHandler(httpUpgradeRequestHandler)
                    }
                }

                // TLS + proxy
                // we need to handle connecting with an additional CONNECT request
                let proxyEstablishedPromise = channel.eventLoop.makePromise(of: Void.self)
                let encoder = HTTPRequestEncoder()
                let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes))

                var connectHeaders = proxyHeaders
                connectHeaders.add(name: "Host", value: host)

                let proxyRequestHandler = NIOHTTP1ProxyConnectHandler(
                    targetHost: host,
                    targetPort: port,
                    headers: connectHeaders,
                    deadline: proxyConnectDeadline,
                    promise: proxyEstablishedPromise
                )

                // This code block adds HTTP handlers to allow the proxy request handler to function.
                // They are then removed upon completion only to be re-added in `addHTTPClientHandlers`.
                // This is done because the HTTP decoder is not valid after an upgrade, the CONNECT request being counted as one.
                do {
                    try channel.pipeline.syncOperations.addHandler(encoder)
                    try channel.pipeline.syncOperations.addHandler(decoder)
                    try channel.pipeline.syncOperations.addHandler(proxyRequestHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                proxyEstablishedPromise.futureResult.flatMap {
                    channel.pipeline.removeHandler(decoder)
                }.flatMap {
                    channel.pipeline.removeHandler(encoder)
                }.whenComplete { result in
                    switch result {
                    case .success:
                        do {
                            let tlsHandler = try self.makeTLSHandler(tlsConfiguration: self.configuration.tlsConfiguration, host: host)
                            // The sync methods here are safe because we're on the channel event loop
                            // due to the promise originating on the event loop of the channel.
                            try channel.pipeline.syncOperations.addHandler(tlsHandler)
                            try channel.pipeline.syncOperations.addHTTPClientHandlers(
                                leftOverBytesStrategy: .forwardBytes,
                                withClientUpgrade: config
                            )
                            try channel.pipeline.syncOperations.addHandler(httpUpgradeRequestHandler)
                        } catch {
                            channel.pipeline.close(mode: .all, promise: nil)
                        }
                    case .failure:
                        channel.pipeline.close(mode: .all, promise: nil)
                    }
                }

                return channel.eventLoop.makeSucceededVoidFuture()
            }

        let connect = bootstrap.connect(host: proxy ?? host, port: proxyPort ?? port)
        connect.cascadeFailure(to: upgradePromise)
        return connect.flatMap { channel in
            return upgradePromise.futureResult
        }
    }

    private func makeTLSHandler(tlsConfiguration: TLSConfiguration?, host: String) throws -> NIOSSLClientHandler {
        let context = try NIOSSLContext(
            configuration: self.configuration.tlsConfiguration ?? .makeClientConfiguration()
        )
        let tlsHandler: NIOSSLClientHandler
        do {
            tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: host)
        } catch let error as NIOSSLExtraError where error == .cannotUseIPAddressInSNI {
            tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: nil)
        }
        return tlsHandler
    }

    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            if self.isShutdown.compareExchange(
                expected: false,
                desired: true,
                ordering: .relaxed
            ).exchanged {
                try self.group.syncShutdownGracefully()
            } else {
                throw WebSocketClient.Error.alreadyShutdown
            }
        }
    }
    
    private static func makeBootstrap(on eventLoop: EventLoopGroup) -> NIOClientTCPBootstrapProtocol {
        #if canImport(Network)
        if let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
            return tsBootstrap
        }
        #endif

        if let nioBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            return nioBootstrap
        }

        fatalError("No matching bootstrap found")
    }

    deinit {
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            assert(self.isShutdown.load(ordering: .relaxed), "WebSocketClient not shutdown before deinit.")
        }
    }
}
