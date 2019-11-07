import XCTest
import NIO
import NIOHTTP1
import NIOWebSocket
@testable import WebSocketKit

final class NIOWebSocketClientTests: XCTestCase {
    func testWebSocketEcho() throws {
        let promise = elg.next().makePromise(of: String.self)
        WebSocket.connect(to: "ws://echo.websocket.org", on: elg) { ws in
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

    func testImmediateSend() throws {
        let port = Int.random(in: 8000..<9000)

        let promise = self.elg.next().makePromise(of: String.self)

        let server = try ServerBootstrap(group: self.elg).childChannelInitializer { channel in
            let webSocket = NIOWebSocketServerUpgrader(
                shouldUpgrade: { channel, req in
                    return channel.eventLoop.makeSucceededFuture([:])
                },
                upgradePipelineHandler: { channel, req in
                    return WebSocket.server(on: channel) { ws in
                        ws.send("hello")
                        ws.onText { ws, string in
                            promise.succeed(string)
                            ws.close(promise: nil)
                        }
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
        }.bind(host: "localhost", port: port).wait()

        WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.onText { ws, string in
                ws.send("goodbye")
            }
        }.cascadeFailure(to: promise)

        try XCTAssertEqual(promise.futureResult.wait(), "goodbye")
        try server.close(mode: .all).wait()
    }

    func testClientPingPong() throws {
        let echoServer = WebSocketEchoServer()

        let promise = elg.next().makePromise(of: Data?.self)
        WebSocket.connect(to: "ws://localhost:\(echoServer.port)", on: elg) { ws in
            ws.onPong { ws, buf in
                let data = buf.getData(at: 0, length: buf.readableBytes)
                promise.succeed(data)
                _ = ws.close().cascadeFailure(to: promise)
            }

            ws.send(raw: [UInt8](Data("foo".utf8)), opcode: .ping)
        }.cascadeFailure(to: promise)

        let data = try promise.futureResult.wait()
        XCTAssertEqual(data, Data("foo".utf8))
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
