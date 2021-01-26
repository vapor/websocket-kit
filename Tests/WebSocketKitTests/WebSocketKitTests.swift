import XCTest
import NIO
import NIOHTTP1
import NIOWebSocket
#if canImport(Network)
import NIOTransportServices
#endif
@testable import WebSocketKit

final class WebSocketKitTests: XCTestCase {
    
    func testWebSocketEcho() throws {
        let promise = self.remoteEventGroup.next().makePromise(of: String.self)
        let closePromise = self.remoteEventGroup.next().makePromise(of: Void.self)
        WebSocket.connect(to: "ws://echo.websocket.org", on: self.remoteEventGroup) { ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: closePromise)
            }
        }.cascadeFailure(to: promise)
        try XCTAssertEqual(promise.futureResult.wait(), "hello")
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        
    }
    
    func testWebSocketWithTLSEcho() throws {
        let promise = self.remoteEventGroup.next().makePromise(of: String.self)
        WebSocket.connect(to: "wss://echo.websocket.org", on: self.remoteEventGroup) { ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: nil)
            }
        }.cascadeFailure(to: promise)
        try XCTAssertEqual(promise.futureResult.wait(), "hello")
    }

    func testBadHost() throws {
        XCTAssertThrowsError(
            try WebSocket.connect(
                host: "asdf",
                on: self.remoteEventGroup
            ) { _  in }.wait()
        )
    }

    func testServerClose() throws {
        let port = Int.random(in: 8000..<9000)

        let sendPromise = self.elg.next().makePromise(of: Void.self)
        let serverClose = self.elg.next().makePromise(of: Void.self)
        let clientClose = self.elg.next().makePromise(of: Void.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                if text == "close" {
                    ws.close(promise: serverClose)
                }
            }
        }.bind(host: "localhost", port: port).wait()

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
        let port = Int.random(in: 8000..<9000)

        let sendPromise = self.elg.next().makePromise(of: Void.self)
        let serverClose = self.elg.next().makePromise(of: Void.self)
        let clientClose = self.elg.next().makePromise(of: Void.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
            ws.onClose.cascade(to: serverClose)
        }.bind(host: "localhost", port: port).wait()

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
        let port = Int.random(in: 8000..<9000)

        let promise = self.elg.next().makePromise(of: String.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: nil)
            }
        }.bind(host: "localhost", port: port).wait()

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.onText { ws, string in
                ws.send("goodbye")
                ws.close(promise: nil)
            }
        }.cascadeFailure(to: promise)

        try XCTAssertEqual(promise.futureResult.wait(), "goodbye")
        try server.close(mode: .all).wait()
    }

    func testWebSocketPong() throws {
        let port = Int.random(in: 8000..<9000)

        let pongPromise = self.elg.next().makePromise(of: String.self)
        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onPing { ws in
                ws.close(promise: nil)
            }
        }.bind(host: "localhost", port: port).wait()

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.send(raw: Data(), opcode: .ping)
            ws.onPong { ws in
                pongPromise.succeed("pong")
                ws.close(promise: nil)
            }
        }.cascadeFailure(to: pongPromise)

        try XCTAssertEqual(pongPromise.futureResult.wait(), "pong")
        try server.close(mode: .all).wait()
    }

    func testErrorCode() throws {
        let port = Int.random(in: 8000..<9000)

        let promise = self.elg.next().makePromise(of: WebSocketErrorCode.self)

        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.close(code: .normalClosure, promise: nil)
        }.bind(host: "localhost", port: port).wait()

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
        let port = Int.random(in: 8000..<9000)

        let promise = self.elg.next().makePromise(of: String.self)

        let server = try ServerBootstrap.webSocket(on: self.elg) { req, ws in
            promise.succeed(req.headers.first(name: "Auth")!)
            ws.close(promise: nil)
        }.bind(host: "localhost", port: port).wait()

        WebSocket.connect(
            to: "ws://localhost:\(port)",
            headers: ["Auth": "supersecretsauce"],
            on: self.elg) { ws in
                _ = ws.close()
        }.cascadeFailure(to: promise)

        try XCTAssertEqual(promise.futureResult.wait(), "supersecretsauce")
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

    var elg: EventLoopGroup!
    var remoteEventGroup: EventLoopGroup!
    override func setUp() {
        // needs to be at least two to avoid client / server on same EL timing issues
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        
        #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
                self.remoteEventGroup = NIOTSEventLoopGroup()
            } else {
                self.remoteEventGroup = self.elg
            }
        #else
            self.remoteEventGroup = self.elg
        #endif
    }
    
    override func tearDown() {
        try! self.elg.syncShutdownGracefully()
        #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
                try! self.remoteEventGroup.syncShutdownGracefully()
            }
        #endif
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
