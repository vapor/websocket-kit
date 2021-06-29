import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOWebSocket
import NIOSSL
#if canImport(Network) && swift(>=5.3)
import NIOTransportServices
#endif

internal extension String {
    var isIPAddress: Bool {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
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
    let isShutdown = NIOAtomic.makeAtomic(value: false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = .init()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.group = group
        case .createNew:
            #if canImport(Network) && swift(>=5.3)
                if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
                    self.group = NIOTSEventLoopGroup()
                } else {
                    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                }
            #else
                self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            #endif
        }
        self.configuration = configuration
    }

    
    fileprivate static func makeBootstrap(
        on eventLoop: EventLoopGroup,
        host: String,
        requiresTLS: Bool,
        configuration: Configuration
    ) throws -> NIOClientTCPBootstrap {
        var bootstrap: NIOClientTCPBootstrap
        #if canImport(Network) && swift(>=5.3)
            // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
                // if there is a proxy don't create TLS provider as it will be added at a later point
                // create NIOClientTCPBootstrap with NIOTS TLS provider
                let tlsConfiguration = configuration.tlsConfiguration ?? TLSConfiguration.forClient()
                let parameters = tlsConfiguration.getNWProtocolTLSOptions()
                let tlsProvider = NIOTSClientTLSProvider(tlsOptions: parameters)
                bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
            } else if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
                let tlsConfiguration = configuration.tlsConfiguration ?? TLSConfiguration.forClient()
                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                let hostname = (!requiresTLS || host.isIPAddress || host.isEmpty) ? nil : host
                let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: hostname)
                bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
            } else {
                preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
            }
        #else
            if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
                let tlsConfiguration = configuration.tlsConfiguration ?? TLSConfiguration.forClient()
                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                let hostname = (!requiresTLS || host.isIPAddress || host.isEmpty) ? nil : host
                let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: hostname)
                bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
            } else {
                preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
            }
        #endif

        if requiresTLS {
            return bootstrap.enableTLS()
        }

        return bootstrap
    }
    
    public func connect(
        scheme: String,
        host: String,
        port: Int,
        path: String = "/",
        headers: HTTPHeaders = [:],
        onUpgrade: @escaping (WebSocket, HTTPResponseHead) -> (),
        onRequest: @escaping (HTTPRequestHead) -> () = {_ in }
    ) -> EventLoopFuture<Void> {
        assert(["ws", "wss"].contains(scheme))
        let upgradePromise = self.group.next().makePromise(of: Void.self)
        
        let bootstrap = try! Self.makeBootstrap(
            on: self.group,
            host: host,
            requiresTLS: scheme == "wss",
            configuration: self.configuration
        )
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let httpHandler = HTTPInitialRequestHandler(
                    host: host,
                    path: path,
                    headers: headers,
                    upgradePromise: upgradePromise
                )

                var key: [UInt8] = []
                for _ in 0..<16 {
                    key.append(.random(in: .min ..< .max))
                }
                let websocketUpgrader = NIOWebSocketClientUpgrader(
                    requestKey:  Data(key).base64EncodedString(),
                    maxFrameSize: self.configuration.maxFrameSize,
                    automaticErrorHandling: true,
                    upgradePipelineHandler: { channel, req in
                        return WebSocket.client(on: channel) { ws in
                            onUpgrade(ws, req)
                        }
                    }
                )

                let config: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [websocketUpgrader],
                    completionHandler: { context in
                        upgradePromise.succeed(())
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )

                return channel.pipeline.addHTTPClientHandlers(
                    leftOverBytesStrategy: .forwardBytes,
                    withServerUpgrade: config,
                    withExtraHandlers: [
                        HTTPChannelIntercepter(writeInterceptHandler: { (head) in
                            onRequest(head)
                        })
                    ]
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }

        let connect = bootstrap.connect(host: host, port: port)
        connect.cascadeFailure(to: upgradePromise)
        return connect.flatMap { channel in
            return upgradePromise.futureResult
        }
    }


    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
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
