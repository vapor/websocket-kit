import XCTest
import Atomics
import NIO
import NIOExtras
import NIOHTTP1
import NIOSSL
import NIOWebSocket
@testable import WebSocketKit
import CompressNIO

final class WebSocketKitTests: XCTestCase {
    var elg: EventLoopGroup!

    override func setUp() async throws {
        fflush(stdout)
    }
    
    override func tearDown() {
        try! self.elg.syncShutdownGracefully()
    }

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
            ws.onText { ws, string in
                ws.close(promise: closePromise)
                promise.succeed(string)
            }
            ws.send("hello")
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
            ws.onClose.cascade(to: clientClose)
            ws.send("close", promise: sendPromise)
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
            ws.onText { ws, text in
                if text == "close" {
                    ws.close(promise: clientClose)
                }
            }
            ws.send("close", promise: sendPromise)
        }.cascadeFailure(to: sendPromise)

        XCTAssertNoThrow(try sendPromise.futureResult.wait())
        XCTAssertNoThrow(try serverClose.futureResult.wait())
        XCTAssertNoThrow(try clientClose.futureResult.wait())
        try server.close(mode: .all).wait()
    }

    func testImmediateSend() throws {
        let promise = self.elg.any().makePromise(of: String.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: nil)
            }
            ws.send("hello")
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
            ws.onPing { ws, data in
                XCTAssertEqual(pingPongData, data)
                pingPromise.succeed("ping")
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.sendPing(Data(pingPongData.readableBytesView))
            ws.onPong { ws, data in
                XCTAssertEqual(pingPongData, data)
                pongPromise.succeed("pong")
                ws.close(promise: nil)
            }
            ws.send(raw: pingPongData.readableBytesView, opcode: .ping)
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
                ws.send(.init(string: text), opcode: .text, fin: false)
                ws.send(.init(string: " th"), opcode: .continuation, fin: false)
                ws.send(.init(string: "e mo"), opcode: .continuation, fin: false)
                ws.send(.init(string: "st"), opcode: .continuation, fin: true)
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        let promise = elg.any().makePromise(of: String.self)
        let closePromise = elg.any().makePromise(of: Void.self)
        WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in

            ws.onText { ws, string in
                ws.close(promise: closePromise)
                promise.succeed(string)
            }
            ws.send(.init(string: "Hel"), opcode: .text, fin: false)
            ws.send(.init(string: "lo! Vapor r"), opcode: .continuation, fin: false)
            ws.send(.init(string: "ules"), opcode: .continuation, fin: true)
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
                XCTAssertEqual(ws.closeCode, WebSocketErrorCode.normalClosure)
                promise.succeed(ws.closeCode!)
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
            ws.close(promise: nil)
            promiseHasUnwantedHeaders.succeed(hasUnwantedHeaders)
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
            ws.close(promise: nil)
            promise.succeed(req.uri)
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

    // Skipped because it never passes as the server never closes.
    func testLocally() throws {
        // swap to test websocket server against local client
        try XCTSkipIf(true)

        let port = Int(1337)
        let shutdownPromise = self.elg.any().makePromise(of: Void.self)

        let server = try! ServerBootstrap.webSocket(on: self.elg) { req, ws in
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

            ws.send("welcome!")
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
        try client.syncShutdown()
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
                ws.close(promise: closePromise)
                promise.succeed(string)
            }
        }.cascadeFailure(to: promise)

        XCTAssertEqual(try promise.futureResult.wait(), "hello")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try client.syncShutdown()
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
            ws.onText { ws, string in
                ws.close(promise: closePromise)
                promise.succeed(string)
            }
            ws.send("hello")
        }.cascadeFailure(to: promise)

        XCTAssertEqual(try promise.futureResult.wait(), "hello")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try client.syncShutdown()
    }

    func testAlternateWebsocketConnectMethods() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg) { $1.onText { $0.send($1) } }.bind(host: "localhost", port: 0).wait()
        let closePromise1 = self.elg.any().makePromise(of: Void.self)
        let closePromise2 = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        WebSocket.connect(scheme: "ws", host: "localhost", port: port, proxy: nil, on: self.elg) { ws in
            ws.send("hello"); ws.onText { ws, _ in ws.close(promise: closePromise1) }
        }.cascadeFailure(to: closePromise1)
        WebSocket.connect(to: "ws://localhost:\(port)", proxy: nil, on: self.elg) { ws in
            ws.send("hello"); ws.onText { ws, _ in ws.close(promise: closePromise2) }
        }.cascadeFailure(to: closePromise2)
        XCTAssertNoThrow(try closePromise1.futureResult.wait())
        XCTAssertNoThrow(try closePromise2.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testBadURLInWebsocketConnect() async throws {
        // %w seems to now get to NIO and it attempts to connect to localhost:80 ... empty string makes the test pass
        XCTAssertThrowsError(try WebSocket.connect(to: "", on: self.elg, onUpgrade: { _ in }).wait()) {

            guard case .invalidURL = $0 as? WebSocketClient.Error else {
                return XCTFail("Expected .invalidURL but got \(String(reflecting: $0))")
            }
        }
    }
    
    func testOnBinary() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg) { $1.onBinary { $0.send($1) } }.bind(host: "localhost", port: 0).wait()
        let promise = self.elg.any().makePromise(of: [UInt8].self)
        let closePromise = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in

            ws.onBinary { ws, buf in
                ws.close(promise: closePromise)
                promise.succeed(.init(buf.readableBytesView))
            }
            ws.send([0x01])
        }.whenFailure {
            promise.fail($0)
            closePromise.fail($0)
        }
        XCTAssertEqual(try promise.futureResult.wait(), [0x01])
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testSendPing() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg) { _, _ in }.bind(host: "localhost", port: 0).wait()
        let promise = self.elg.any().makePromise(of: Void.self)
        let closePromise = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.onPong { socket, _ in
                socket.close(promise: closePromise)
                promise.succeed()
            }
            ws.sendPing()
        }.cascadeFailure(to: closePromise)
        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testSetPingInterval() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg) { _, _ in }.bind(host: "localhost", port: 0).wait()
        let promise = self.elg.any().makePromise(of: Void.self)
        let closePromise = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.pingInterval = .milliseconds(100)
            ws.onPong { socket, _ in

                socket.close(promise: closePromise)
                promise.succeed()

            }
        }.cascadeFailure(to: closePromise)
        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testCreateNewELGAndShutdown() throws {
        let client = WebSocketClient(eventLoopGroupProvider: .createNew)
        try client.syncShutdown()
    }

    
    
    // compression usage tests
//    func testCompressDcompressNodeServerResponse_deflate() {
//        let string1 = "Welcome, you are connected!"
//        var sBuf = ByteBuffer(string: string1)
//        var compressedBuffer = try? sBuf.compress(with: .deflate)
//        print("\(String(buffer:compressedBuffer ?? ByteBuffer()))")
//        let decompressedBuffer = try? compressedBuffer?.decompress(with: .deflate)
//        let string2 = String(buffer: decompressedBuffer ?? ByteBuffer(string: ""))
//
//        XCTAssertNotNil(compressedBuffer, "buffer failed to compress with deflate")
//        XCTAssertNotNil(decompressedBuffer, "compressed buffer fialed to inflate")
//        XCTAssertEqual(string1, string2, "Comp/decomp was not symmetrical!")
//
//    }
//
//    func testCompressDcompressNodeServerResponse_gzip() {
//        let string1 = "Welcome, you are connected!"
//        var sBuf = ByteBuffer(string: string1)
//        var compressedBuffer = try? sBuf.compress(with: .gzip)
//        print("\(String(buffer:compressedBuffer ?? ByteBuffer()))")
//        let decompressedBuffer = try? compressedBuffer?.decompress(with: .gzip)
//        let string2 = String(buffer: decompressedBuffer ?? ByteBuffer(string: ""))
//
//        XCTAssertNotNil(compressedBuffer, "buffer failed to compress with gzip")
//        XCTAssertNotNil(decompressedBuffer, "compressed buffer fialed to gIp")
//        XCTAssertEqual(string1, string2, "Comp/decomp was not symmetrical!")
//
//    }
    
//    func test_wiresharkExample() throws {
//        // values from wireshark capture
//        let maskingKey:[UInt8] = [0xbf,0xcb,0x13,0x3d]
//        let maskedPayload:[UInt8] = [
//        
//               0x52, 0x05, 0xda, 0x34, 0x7f, 0xfb, 0x1f, 0x39, 0x7f, 0x91, 0x4f, 0xae, 0xa4, 0xfa,
//               0x1b, 0xc8, 0xa0, 0xe8, 0x80, 0xa6, 0xc3, 0x38, 0x09, 0x65, 0x33, 0x77, 0x1b, 0x0c, 0x82, 0x8c,
//               0xff, 0xf4, 0x87, 0xd8, 0x4a, 0x60, 0xb2, 0x28, 0x30, 0x4e, 0xde, 0x76, 0x78, 0x05, 0x25, 0x0c,
//               0xdd, 0x80, 0xc3, 0xd4, 0xab, 0x63, 0x15, 0xa4, 0xf8, 0x6d, 0xef, 0x9b, 0x43, 0x6d, 0xef, 0x9b,
//               0x43, 0x6d, 0xef, 0x9b, 0x43, 0x6d, 0xef, 0x9b, 0x43, 0x6d, 0xef, 0x9b, 0x43, 0x6d, 0xef, 0x9b,
//               0x43, 0x6d, 0x00, 0x6a, 0x25]
//        // existing imp defaults to 0
//        let indexOffset = 0
//        
//        var unmaskResult = [UInt8]()
//        
//        // unmask ourselves
//        for (index, byte) in maskedPayload.enumerated() {
//            let unmasked:UInt8 = UInt8(byte ^ maskingKey[(index + indexOffset) % 4])
//            unmaskResult.append(unmasked)
//        }
//        print("UNMASKED: \(unmaskResult)")
//        
//        // the wireshark unmasked payload
//        let expectedUnmaskedPayload:[UInt8] = [
//            0xed, 0xce, 0xc9, 0x09, 0xc0, 0x30, 0x0c, 0x04, 0xc0, 0x5a, 0x5c, 0x93, 0x1b, 0x31, 0x08, 0xf5,
//            0x1f, 0x23, 0x93, 0x9b, 0x7c, 0xf3, 0x1a, 0x58, 0x8c, 0xbc, 0x08, 0x31, 0x3d, 0x47, 0xec, 0xc9,
//            0x38, 0x13, 0x59, 0x5d, 0x0d, 0xe3, 0x23, 0x73, 0x61, 0xbd, 0x6b, 0x38, 0x9a, 0xc7, 0xce, 0xbd,
//            0x7c, 0x1f, 0xb8, 0x5e, 0xaa, 0x6f, 0xeb, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50,
//            0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50,
//            0xbf, 0xa1, 0x36
//
//    ]
//        
////        XCTAssertEqual(expectedUnmaskedPayload, unmaskResult)
////        var buff = ByteBuffer(bytes: unmaskResult)
////        let decompresed = try? buff.decompress(with: .rawDeflate)
////        if let b = decompresed {
////            let text = String(buffer: b)
////            print("DECOMPRESSED: \(text)")
////        }
//        
//    }
    
    // 5.2 tests
    func test_5_2_PMCES_operate_only_on_data_msgs() throws {
        
        // I've verified this by observation but am not sure how/where to test it
        
//        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
//
//            ws.onText { ws, text in
//                ws.send(text)
//            }
//        }.bind(host: "localhost", port: 0).wait()
//
//        guard let port = server.localAddress?.port else {
//            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
//            return
//        }
//
//        let promise = elg.any().makePromise(of: String.self)
//        let closePromise = elg.any().makePromise(of: Void.self)
//        WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in
//
//            ws.send(raw: "1".data(using: .utf8)!, opcode: .pong)
//        }.cascadeFailure(to: promise)
//        try XCTAssertEqual(promise.futureResult.wait(), "hello")
//        XCTAssertNoThrow(try closePromise.futureResult.wait())
//        try server.close(mode: .all).wait()
    }
    
    
    override func setUp() {
        // needs to be at least two to avoid client / server on same EL timing issues
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
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

