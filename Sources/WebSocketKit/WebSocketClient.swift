import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import NIOExtras
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOTransportServices
import Atomics

public final class WebSocketClient: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case invalidURL
        case invalidResponseStatus(HTTPResponseHead)
        case alreadyShutdown
        public var errorDescription: String? {
            return "\(self)"
        }
    }

    public typealias EventLoopGroupProvider = NIOEventLoopGroupProvider

    public struct Configuration: Sendable {
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

    @preconcurrency
    public func connect(
        scheme: String,
        host: String,
        port: Int,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        self.connect(scheme: scheme, host: host, port: port, path: path, query: query, headers: headers, proxy: nil, onUpgrade: onUpgrade)
    }

    /// Establish a WebSocket connection via a proxy server.
    ///
    /// - Parameters:
    ///   - scheme: Scheme component of the URI for the origin server.
    ///   - host: Host component of the URI for the origin server.
    ///   - port: Port on which to connect to the origin server.
    ///   - path: Path component of the URI for the origin server.
    ///   - query: Query component of the URI for the origin server.
    ///   - headers: Headers to send to the origin server.
    ///   - proxy: Host component of the URI for the proxy server.
    ///   - proxyPort: Port on which to connect to the proxy server.
    ///   - proxyHeaders: Headers to send to the proxy server.
    ///   - proxyConnectDeadline: Deadline for establishing the proxy connection.
    ///   - onUpgrade: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`.
    /// - Returns: A future which completes when the connection to the origin server is established.
    @preconcurrency
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
        onUpgrade: @Sendable @escaping (WebSocket) -> ()
    ) -> EventLoopFuture<Void> {
        assert(["ws", "wss"].contains(scheme))
        let upgradePromise = self.group.any().makePromise(of: Void.self)
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
                let httpUpgradeRequestHandlerBox = NIOLoopBound(httpUpgradeRequestHandler, eventLoop: channel.eventLoop)

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
                        channel.pipeline.removeHandler(httpUpgradeRequestHandlerBox.value, promise: nil)
                    }
                )
                let configBox = NIOLoopBound(config, eventLoop: channel.eventLoop)

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
                        channel.pipeline.addHandler(httpUpgradeRequestHandlerBox.value)
                    }
                }

                // TLS + proxy
                // we need to handle connecting with an additional CONNECT request
                let proxyEstablishedPromise = channel.eventLoop.makePromise(of: Void.self)
                let encoder = NIOLoopBound(HTTPRequestEncoder(), eventLoop: channel.eventLoop)
                let decoder = NIOLoopBound(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)), eventLoop: channel.eventLoop)

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
                    try channel.pipeline.syncOperations.addHandler(encoder.value)
                    try channel.pipeline.syncOperations.addHandler(decoder.value)
                    try channel.pipeline.syncOperations.addHandler(proxyRequestHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                proxyEstablishedPromise.futureResult.flatMap {
                    channel.pipeline.removeHandler(decoder.value)
                }.flatMap {
                    channel.pipeline.removeHandler(encoder.value)
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
                                withClientUpgrade: configBox.value
                            )
                            try channel.pipeline.syncOperations.addHandler(httpUpgradeRequestHandlerBox.value)
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

    @Sendable
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
