import XCTest
import NIO
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

        let promise = elg.next().makePromise(of: String.self)
        let closePromise = elg.next().makePromise(of: Void.self)
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
        let sendPromise = self.elg.next().makePromise(of: Void.self)
        let serverClose = self.elg.next().makePromise(of: Void.self)
        let clientClose = self.elg.next().makePromise(of: Void.self)
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
        let sendPromise = self.elg.next().makePromise(of: Void.self)
        let serverClose = self.elg.next().makePromise(of: Void.self)
        let clientClose = self.elg.next().makePromise(of: Void.self)
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
        let promise = self.elg.next().makePromise(of: String.self)
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
        let pingPromise = self.elg.next().makePromise(of: String.self)
        let pongPromise = self.elg.next().makePromise(of: String.self)
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

    func testErrorCode() throws {
        let promise = self.elg.next().makePromise(of: WebSocketErrorCode.self)

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
        let promiseAuth = self.elg.next().makePromise(of: String.self)
        
        // make sure there is no content-length header
        let promiseNoContentLength = self.elg.next().makePromise(of: Bool.self)
        
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            promiseAuth.succeed(req.headers.first(name: "Auth")!)
            promiseNoContentLength.succeed(req.headers.contains(name: "content-length"))
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
        try XCTAssertFalse(promiseNoContentLength.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testQueryParamsAreSent() throws {
        let promise = self.elg.next().makePromise(of: String.self)

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
        let shutdownPromise = self.elg.next().makePromise(of: Void.self)

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
    
    func testIP() throws {
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.close(promise: nil)
        }.bind(host: "127.0.0.1", port: 1111).wait()

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none

        let client = WebSocketClient(eventLoopGroupProvider: .shared(self.elg), configuration: .init(
            tlsConfiguration: tlsConfiguration
        ))

        try client.connect(scheme: "wss", host: "127.0.0.1", port: 1111) { ws in
            ws.close(promise: nil)
        }.wait()
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
        onUpgrade: @escaping (HTTPRequestHead, WebSocket) -> ()
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup).childChannelInitializer { channel in
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
