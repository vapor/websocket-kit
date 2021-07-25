import XCTest
import NIO
import NIOHTTP1
import NIOWebSocket
@testable import WebSocketKit

final class WebSocketKitTests: XCTestCase {
    func testWebSocketEcho() throws {
        let promise = elg.next().makePromise(of: String.self)
        let closePromise = elg.next().makePromise(of: Void.self)
        WebSocket.connect(to: "ws://echo.websocket.org", on: elg) { ws in
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
        let promise = elg.next().makePromise(of: String.self)
        WebSocket.connect(to: "wss://echo.websocket.org", on: elg) { ws in
            ws.send("hello")
            ws.onText { ws, string in
                promise.succeed(string)
                ws.close(promise: nil)
            }
        }.cascadeFailure(to: promise)
        try XCTAssertEqual(promise.futureResult.wait(), "hello")
    }

    func testBadHost() throws {
        XCTAssertThrowsError(try WebSocket.connect(host: "asdf", on: elg) { _  in }.wait())
    }
    
    
    func testMutliFrameMessage() throws {
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
        let config = WebSocketClient.Configuration(tlsConfiguration: nil, maxFrameSize: 2)
        WebSocket.connect(to: "ws://localhost:\(port)", configuration: config, on: self.elg) { ws in
            ws.send("close", promise: sendPromise)
            ws.onClose.cascade(to: clientClose)
        }.cascadeFailure(to: sendPromise)

        XCTAssertNoThrow(try sendPromise.futureResult.wait())
        XCTAssertNoThrow(try serverClose.futureResult.wait())
        XCTAssertNoThrow(try clientClose.futureResult.wait())
        try server.close(mode: .all).wait()
    }
    
    func testMultiFrameMessageOrdering() throws {
        let port = Int.random(in: 8000..<9000)

        // Sending from client to server
        let sendMultiFrameMessagePromise = self.elg.next().makePromise(of: Void.self)
        let sendSingleFrameMessagePromise = self.elg.next().makePromise(of: Void.self)
        
        // received on server
        let receivedMultiFrameMessagePromise = self.elg.next().makePromise(of: Void.self)
        let receivedSingleFrameMessagePromise = self.elg.next().makePromise(of: Void.self)
        
        // received echo on client
        let receivedMultiFrameMessageEchoPromise = self.elg.next().makePromise(of: Void.self)
        let receivedSingleFrameMessageEchoPromise = self.elg.next().makePromise(of: Void.self)

        
        let clientClose = self.elg.next().makePromise(of: Void.self)
        let serverClose = self.elg.next().makePromise(of: Void.self)
        
        let maxFrameSize: WebSocketMaxFrameSize = 13

        let server = try ServerBootstrap.webSocket(
            on: self.elg,
            outboundMaxFrameSize: maxFrameSize,
            inboundMaxFrameSize: maxFrameSize
        ) { req, ws in
            ws.onClose.cascade(to: serverClose)
            
            ws.onText { ws, text in
                receivedSingleFrameMessagePromise.succeed(())
                ws.send(text, promise: nil)
            }
            
            ws.onBinary { ws, buffer in
                receivedMultiFrameMessagePromise.succeed(())
                ws.send(buffer: buffer, opcode: .binary, promise: nil)
            }
        }.bind(host: "localhost", port: port).wait()
        
        let config = WebSocketClient.Configuration(tlsConfiguration: nil, maxFrameSize: maxFrameSize)
        
        WebSocket.connect(to: "ws://localhost:\(port)", configuration: config, on: self.elg) { ws in
            ws.onBinary { ws, buffer in
                XCTAssertEqual(buffer.readableBytes, 10000)
                receivedMultiFrameMessageEchoPromise.succeed(())
            }
            
            ws.onText { ws, str in
                XCTAssertEqual(str, "singleFrame")
                receivedSingleFrameMessageEchoPromise.succeed(())
            }
                        
            ws.send(buffer: ByteBuffer(repeating: 1, count: 10000), opcode: .binary, promise: sendMultiFrameMessagePromise)

            sendMultiFrameMessagePromise.futureResult.whenSuccess { _ in
                ws.send("singleFrame", promise: sendSingleFrameMessagePromise)
            }
            
            // Send close after Multi frame response has arrived.
            receivedMultiFrameMessageEchoPromise.futureResult.whenComplete { _ in
                ws.close(promise: clientClose)
            }
        }.cascadeFailure(to: clientClose)
        
        XCTAssertNoThrow(try sendMultiFrameMessagePromise.futureResult.wait())
        XCTAssertNoThrow(try sendSingleFrameMessagePromise.futureResult.wait())

        XCTAssertNoThrow(try receivedMultiFrameMessagePromise.futureResult.wait())
        XCTAssertNoThrow(try receivedSingleFrameMessagePromise.futureResult.wait())
        
        XCTAssertNoThrow(try receivedMultiFrameMessageEchoPromise.futureResult.wait())
        XCTAssertNoThrow(try receivedSingleFrameMessageEchoPromise.futureResult.wait())
        
        XCTAssertNoThrow(try clientClose.futureResult.wait())

        try server.close(mode: .all).wait()
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
        outboundMaxFrameSize: WebSocketMaxFrameSize = .default,
        inboundMaxFrameSize: WebSocketMaxFrameSize = .default,
        onUpgrade: @escaping (HTTPRequestHead, WebSocket) -> ()
        
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup).childChannelInitializer { channel in
            let webSocket = NIOWebSocketServerUpgrader(
                maxFrameSize: inboundMaxFrameSize.value,
                shouldUpgrade: { channel, req in
                    return channel.eventLoop.makeSucceededFuture([:])
                },
                upgradePipelineHandler: { channel, req in
                    return WebSocket.server(on: channel, outboundMaxFrameSize: outboundMaxFrameSize) { ws in
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
