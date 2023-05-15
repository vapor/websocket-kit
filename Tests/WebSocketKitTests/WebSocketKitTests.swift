import XCTest
import Atomics
import NIO
import NIOExtras
import NIOHTTP1
import NIOSSL
import NIOWebSocket
@testable import WebSocketKit

final class WebSocketKitTests: XCTestCase {
    func testWebSocketEcho() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        let promise = elg.any().makePromise(of: String.self)
        let closePromise = elg.any().makePromise(of: Void.self)
        WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: closePromise)
            }
        }.cascadeFailure(to: promise)
        try XCTAssertEqual(promise.futureResult.wait(), "hello")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try server.close(mode: .all).wait()
    }

    func testBadHost() throws {
        XCTAssertThrowsError(try WebSocket.connect(host: "asdf", on: elg) { _  in }.wait())
    }

    func testServerClose() throws {
        let sendPromise = self.elg.any().makePromise(of: Void.self)
        let serverClose = self.elg.any().makePromise(of: Void.self)
        let clientClose = self.elg.any().makePromise(of: Void.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                if text == "close" {
                    ws.close(promise: serverClose)
                }
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.send("close", promise: sendPromise)
            ws.onClose.cascade(to: clientClose)
        }.cascadeFailure(to: sendPromise)

        XCTAssertNoThrow(try sendPromise.futureResult.wait())
        XCTAssertNoThrow(try serverClose.futureResult.wait())
        XCTAssertNoThrow(try clientClose.futureResult.wait())
        try server.close(mode: .all).wait()
    }

    func testClientClose() throws {
        let sendPromise = self.elg.any().makePromise(of: Void.self)
        let serverClose = self.elg.any().makePromise(of: Void.self)
        let clientClose = self.elg.any().makePromise(of: Void.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
            ws.onClose.cascade(to: serverClose)
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.send("close", promise: sendPromise)
            ws.onText { ws, text in
                if text == "close" {
                    ws.close(promise: clientClose)
                }
            }
        }.cascadeFailure(to: sendPromise)

        XCTAssertNoThrow(try sendPromise.futureResult.wait())
        XCTAssertNoThrow(try serverClose.futureResult.wait())
        XCTAssertNoThrow(try clientClose.futureResult.wait())
        try server.close(mode: .all).wait()
    }

    func testImmediateSend() throws {
        let promise = self.elg.any().makePromise(of: String.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: nil)
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.onText { ws, string in
                ws.send("goodbye")
                ws.close(promise: nil)
            }
        }.cascadeFailure(to: promise)

        try XCTAssertEqual(promise.futureResult.wait(), "goodbye")
        try server.close(mode: .all).wait()
    }

    func testWebSocketPingPong() throws {
        let pingPromise = self.elg.any().makePromise(of: String.self)
        let pongPromise = self.elg.any().makePromise(of: String.self)
        let pingPongData = ByteBuffer(bytes: "Vapor rules".utf8)

        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onPing { ws in
                pingPromise.succeed("ping")
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.send(raw: pingPongData.readableBytesView, opcode: .ping)
            ws.onPong { ws in
                pongPromise.succeed("pong")
                ws.close(promise: nil)
            }
        }.cascadeFailure(to: pongPromise)

        try XCTAssertEqual(pingPromise.futureResult.wait(), "ping")
        try XCTAssertEqual(pongPromise.futureResult.wait(), "pong")
        try server.close(mode: .all).wait()
    }

    func testWebSocketAggregateFrames() throws {
        func byteBuffView(_ str: String) -> ByteBufferView {
            ByteBuffer(string: str).readableBytesView
        }

        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                ws.send(text, opcode: .text, fin: false)
                ws.send(" th", opcode: .continuation, fin: false)
                ws.send("e mo", opcode: .continuation, fin: false)
                ws.send("st", opcode: .continuation, fin: true)
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        let promise = elg.any().makePromise(of: String.self)
        let closePromise = elg.any().makePromise(of: Void.self)
        WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in
            ws.send("Hel", opcode: .text, fin: false)
            ws.send("lo! Vapor r", opcode: .continuation, fin: false)
            ws.send("ules", opcode: .continuation, fin: true)
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: closePromise)
            }
        }.cascadeFailure(to: promise)
        try XCTAssertEqual(promise.futureResult.wait(), "Hello! Vapor rules the most")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try server.close(mode: .all).wait()
    }

    func testErrorCode() throws {
        let promise = self.elg.any().makePromise(of: WebSocketErrorCode.self)

        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.close(code: .normalClosure, promise: nil)
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.onText { ws, string in
                ws.send("goodbye")
            }
            ws.onClose.whenSuccess {
                promise.succeed(ws.closeCode!)
                XCTAssertEqual(ws.closeCode, WebSocketErrorCode.normalClosure)
            }
        }.cascadeFailure(to: promise)

        try XCTAssertEqual(promise.futureResult.wait(), WebSocketErrorCode.normalClosure)
        try server.close(mode: .all).wait()
    }

    func testHeadersAreSent() throws {
        let promiseAuth = self.elg.any().makePromise(of: String.self)
        
        // make sure there are no unwanted headers such as `Content-Length` or `Content-Type`
        let promiseHasUnwantedHeaders = self.elg.any().makePromise(of: Bool.self)
        
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            let headers = req.headers

            promiseAuth.succeed(headers.first(name: "Auth")!)

            let hasUnwantedHeaders = (
                headers.contains(name: "Content-Length") ||
                headers.contains(name: "Content-Type")
            )
            promiseHasUnwantedHeaders.succeed(hasUnwantedHeaders)

            ws.close(promise: nil)
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(
            to: "ws://localhost:\(port)",
            headers: ["Auth": "supersecretsauce"],
            on: self.elg) { ws in
                _ = ws.close()
            }.cascadeFailure(to: promiseAuth)

        try XCTAssertEqual(promiseAuth.futureResult.wait(), "supersecretsauce")
        try XCTAssertFalse(promiseHasUnwantedHeaders.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testQueryParamsAreSent() throws {
        let promise = self.elg.any().makePromise(of: String.self)

        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            promise.succeed(req.uri)
            ws.close(promise: nil)
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(
            to: "ws://localhost:\(port)?foo=bar&bar=baz",
            on: self.elg) { ws in
                _ = ws.close()
        }.cascadeFailure(to: promise)

        try XCTAssertEqual(promise.futureResult.wait(), "/?foo=bar&bar=baz")
        try server.close(mode: .all).wait()
    }

    func testLocally() throws {
        // swap to test websocket server against local client
        try XCTSkipIf(true)

        let port = Int(1337)
        let shutdownPromise = self.elg.any().makePromise(of: Void.self)

        let server = try! ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.send("welcome!")

            ws.onClose.whenComplete {
                print("ws.onClose done: \($0)")
            }

            ws.onText { ws, text in
                switch text {
                case "shutdown":
                    shutdownPromise.succeed(())
                case "close":
                    ws.close().whenComplete {
                        print("ws.close() done \($0)")
                    }
                default:
                    ws.send(text.reversed())
                }
            }
        }.bind(host: "localhost", port: port).wait()
        print("Serving at ws://localhost:\(port)")

        print("Waiting for server shutdown...")
        try shutdownPromise.futureResult.wait()

        print("Waiting for server close...")
        try server.close(mode: .all).wait()
    }
    
    func testIPWithTLS() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg, tls: true) { req, ws in
            _ = ws.close()
        }.bind(host: "127.0.0.1", port: 0).wait()

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none
        
        let client = WebSocketClient(
            eventLoopGroupProvider: .shared(self.elg),
            configuration: .init(
                tlsConfiguration: tlsConfiguration
            )
        )

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        try client.connect(scheme: "wss", host: "127.0.0.1", port: port) { ws in
            ws.close(promise: nil)
        }.wait()
        
        try server.close(mode: .all).wait()
    }

    func testProxy() throws {
        let promise = elg.any().makePromise(of: String.self)

        let localWebsocketBin: WebsocketBin
        let verifyProxyHead = { (ctx: ChannelHandlerContext, requestHead: HTTPRequestHead) in
            XCTAssertEqual(requestHead.uri, "ws://apple.com/:\(ctx.localAddress!.port!)")
            XCTAssertEqual(requestHead.headers.first(name: "Host"), "apple.com")
        }
        localWebsocketBin = WebsocketBin(
            .http1_1(ssl: false),
            proxy: .simulate(
                config: WebsocketBin.ProxyConfig(tls: false, headVerification: verifyProxyHead),
                authorization: "token amFwcGxlc2VlZDpwYXNzMTIz"
            ),
            sslContext: nil
        ) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
        }

        defer {
            XCTAssertNoThrow(try localWebsocketBin.shutdown())
        }

        let closePromise = elg.any().makePromise(of: Void.self)

        let client = WebSocketClient(
            eventLoopGroupProvider: .shared(self.elg),
            configuration: .init()
        )

        client.connect(
            scheme: "ws",
            host: "apple.com",
            port: localWebsocketBin.port,
            proxy: "localhost",
            proxyPort: localWebsocketBin.port,
            proxyHeaders: HTTPHeaders([("proxy-authorization", "token amFwcGxlc2VlZDpwYXNzMTIz")])
        ) { ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: closePromise)
            }
        }.cascadeFailure(to: promise)

        XCTAssertEqual(try promise.futureResult.wait(), "hello")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
    }

    func testProxyTLS() throws {
        let promise = elg.any().makePromise(of: String.self)

        let (cert, key) = generateSelfSignedCert()
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(cert)],
            privateKey: .privateKey(key)
        )
        let sslContext = try! NIOSSLContext(configuration: configuration)

        let verifyProxyHead = { (ctx: ChannelHandlerContext, requestHead: HTTPRequestHead) in
            // CONNECT uses a special form of request target, unique to this method, consisting of
            // only the host and port number of the tunnel destination, separated by a colon.
            // https://httpwg.org/specs/rfc9110.html#CONNECT
            XCTAssertEqual(requestHead.uri, "apple.com:\(ctx.localAddress!.port!)")
            XCTAssertEqual(requestHead.headers.first(name: "Host"), "apple.com")
        }
        let localWebsocketBin = WebsocketBin(
            .http1_1(ssl: true),
            proxy: .simulate(
                config: WebsocketBin.ProxyConfig(tls: true, headVerification: verifyProxyHead),
                authorization: "token amFwcGxlc2VlZDpwYXNzMTIz"
            ),
            sslContext: sslContext
        ) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
        }

        defer {
            XCTAssertNoThrow(try localWebsocketBin.shutdown())
        }

        let closePromise = elg.any().makePromise(of: Void.self)
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none

        let client = WebSocketClient(
            eventLoopGroupProvider: .shared(self.elg),
            configuration: .init(
                tlsConfiguration: tlsConfiguration
            )
        )

        client.connect(
            scheme: "wss",
            host: "apple.com",
            port: localWebsocketBin.port,
            proxy: "localhost",
            proxyPort: localWebsocketBin.port,
            proxyHeaders: HTTPHeaders([("proxy-authorization", "token amFwcGxlc2VlZDpwYXNzMTIz")])
        ) { ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: closePromise)
            }
        }.cascadeFailure(to: promise)

        XCTAssertEqual(try promise.futureResult.wait(), "hello")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
    }


    var elg: EventLoopGroup!
    override func setUp() {
        // needs to be at least two to avoid client / server on same EL timing issues
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }
    override func tearDown() {
        try! self.elg.syncShutdownGracefully()
    }
}

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

fileprivate extension WebSocket {
    func send(
        _ data: String,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        self.send(raw: ByteBuffer(string: data).readableBytesView, opcode: opcode, fin: fin, promise: promise)
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

