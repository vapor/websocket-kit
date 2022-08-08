import Foundation
import NIO
import NIOConcurrencyHelpers
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
        assert(["ws", "wss"].contains(scheme))
        let upgradePromise = self.group.next().makePromise(of: Void.self)
        let bootstrap = WebSocketClient.makeBootstrap(on: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let httpHandler = HTTPInitialRequestHandler(
                    host: host,
                    path: path,
                    query: query,
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
                        return WebSocket.client(on: channel, onUpgrade: onUpgrade)
                    }
                )

                let config: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [websocketUpgrader],
                    completionHandler: { context in
                        upgradePromise.succeed(())
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )

                if scheme == "wss" {
                    do {
                        let context = try NIOSSLContext(
                            configuration: self.configuration.tlsConfiguration ?? .makeClientConfiguration()
                        )
                        let tlsHandler: NIOSSLClientHandler
                        do {
                            tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: host)
                        } catch let error as NIOSSLExtraError where error == .cannotUseIPAddressInSNI {
                            tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: nil)
                        }
                        return channel.pipeline.addHandler(tlsHandler).flatMap {
                            channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, withClientUpgrade: config)
                        }.flatMap {
                            channel.pipeline.addHandler(httpHandler)
                        }
                    } catch {
                        return channel.pipeline.close(mode: .all)
                    }
                } else {
                    return channel.pipeline.addHTTPClientHandlers(
                        leftOverBytesStrategy: .forwardBytes,
                        withClientUpgrade: config
                    ).flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
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
