#if compiler(>=5.5) && canImport(_Concurrency)
import XCTest
import NIO
import NIOHTTP1
import NIOWebSocket
import Logging
@testable import WebSocketKit

@available(macOS 12, iOS 15, watchOS 8, tvOS 15, *)
final class AsyncWebSocketKitTests: XCTestCase {
    func testWebSocketEcho() async throws {
        let server = try ServerBootstrap.webSocket(on: self.elg, logger: self.logger) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        let promise = elg.next().makePromise(of: String.self)

        try await WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in
            do {
                try await ws.send("hello")
                ws.onText { ws, string in
                    promise.succeed(string)
                    do {
                        try await ws.close()
                    } catch {
                        XCTFail("Failed to close websocket, error: \(error)")
                    }
                }
            } catch {
                promise.fail(error)
            }
        }

        let result = try await promise.futureResult.get()
        XCTAssertEqual(result, "hello")
        try await server.close(mode: .all)
    }

    func testWebSocketSendCodable() async throws {
        let server = try ServerBootstrap.webSocket(on: self.elg, logger: self.logger) { req, ws in
            ws.onEvent("hello", User.self) { ws, user in
                ws.send("Hello \(user.firstName) \(user.lastName)")
            }
        }.bind(host: "localhost", port: 0).wait()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        let promise = elg.next().makePromise(of: String.self)

        try await WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in
            do {
                try await ws.send(Response(event: "hello", data: User(firstName: "Vapor", lastName: "WebSocket")))
                ws.onText { ws, string in
                    promise.succeed(string)
                    do {
                        try await ws.close()
                    } catch {
                        XCTFail("Failed to close websocket, error: \(error)")
                    }
                }
            } catch {
                promise.fail(error)
            }
        }

        let result = try await promise.futureResult.get()
        XCTAssertEqual(result, "Hello Vapor WebSocket")
        try await server.close(mode: .all)

        struct Response: Codable {
            let event: String
            let data: User
        }

        struct User: Codable {
            let firstName, lastName: String
        }
    }

    var elg: EventLoopGroup!
    var logger: Logger!
    override func setUp() {
        // needs to be at least two to avoid client / server on same EL timing issues
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.logger = Logger(label: "com.vapor.websocketkit.tests")
    }
    override func tearDown() {
        try! self.elg.syncShutdownGracefully()
    }
}

#endif
