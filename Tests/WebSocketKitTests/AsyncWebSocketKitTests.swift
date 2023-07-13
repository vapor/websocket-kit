import XCTest
import NIO
import NIOHTTP1
import NIOWebSocket
@testable import WebSocketKit

final class AsyncWebSocketKitTests: XCTestCase {

    override func setUp() async throws {
        // Handy for catching hangs in the tests. See https://github.com/apple/swift-corelibs-xctest/issues/422#issuecomment-1310952437
        fflush(stdout)
    }

    func testWebSocketEcho() async throws {
        let server = try await ServerBootstrap.webSocket(on: self.elg) { req, ws in
            ws.onText { ws, text in
                ws.send(text)
            }
        }.bind(host: "localhost", port: 0).get()

        guard let port = server.localAddress?.port else {
            XCTFail("couldn't get port from \(server.localAddress.debugDescription)")
            return
        }

        let promise = elg.any().makePromise(of: String.self)

        try await WebSocket.connect(to: "ws://localhost:\(port)", on: elg) { ws in
            do {
                ws.onText { ws, string in
                    do {
                        try await ws.close()
                    } catch {
                        XCTFail("Failed to close websocket, error: \(error)")
                    }
                    promise.succeed(string)
                }
                try await ws.send("hello")
            } catch {
                promise.fail(error)
            }
        }

        let result = try await promise.futureResult.get()
        XCTAssertEqual(result, "hello")
        try await server.close(mode: .all)
    }
    
    func testBadURLInWebsocketConnect() async throws {
        do {
            // %w seems to now get to NIO and it attempts to connect to localhost:80 ... empty string makes the test pass
            try await WebSocket.connect(to: "", on: self.elg, onUpgrade: { _ async in })
            XCTAssertThrowsError({}())
        } catch {
            XCTAssertThrowsError(try { throw error }()) {
                guard case .invalidURL = $0 as? WebSocketClient.Error else {
                    return XCTFail("Expected .invalidURL but got \(String(reflecting: $0))")
                }
            }
        }
    }

    func testOnBinary() async throws {
        let server = try await ServerBootstrap.webSocket(on: self.elg) { $1.onBinary { $0.send($1) } }.bind(host: "localhost", port: 0).get()
        let promise = self.elg.any().makePromise(of: [UInt8].self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        try await WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { ws in
            ws.onBinary { ws, buf in
                do { try await ws.close() }
                catch { XCTFail("Failed to close websocket: \(String(reflecting: error))") }
                promise.succeed(.init(buf.readableBytesView))
            }

            do {
                try await ws.send([0x01])
            } catch {
                try? await ws.close()
                promise.fail(error);
            }
        }
        let result = try await promise.futureResult.get()
        XCTAssertEqual(result, [0x01])
        try await server.close(mode: .all)
    }

    func testSendPing() async throws {
        let server = try await ServerBootstrap.webSocket(on: self.elg) { _, _ in }.bind(host: "localhost", port: 0).get()
        let promise = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        try await WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { (ws) async in
            ws.onPong {socket, _ in
                do {
                    try await socket.close()
                } catch {
                    XCTFail("Failed to close websocket: \(String(reflecting: error))")
                }
                promise.succeed(())
            }
            do {
                try await ws.sendPing()
            } catch {
                try? await ws.close()
                promise.fail(error)
            }
        }
        try await promise.futureResult.get()
        try await server.close(mode: .all)
    }

    func testSetPingInterval() async throws {
        let server = try await ServerBootstrap.webSocket(on: self.elg) { _, _ in }.bind(host: "localhost", port: 0).get()
        let promise = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        try await WebSocket.connect(to: "ws://localhost:\(port)", on: self.elg) { (ws) async in
            ws.pingInterval = .milliseconds(100)
            ws.onPong { socket, _ in
                
                do { try await socket.close() } catch { XCTFail("Failed to close websocket: \(String(reflecting: error))") }
                promise.succeed(())
            }
        }
        try await promise.futureResult.get()
        try await server.close(mode: .all)
    }

    func testAlternateWebsocketConnectMethods() async throws {
        let server = try await ServerBootstrap.webSocket(on: self.elg) { $1.onText { $0.send($1) } }.bind(host: "localhost", port: 0).get()
        let promise = self.elg.any().makePromise(of: Void.self)
        guard let port = server.localAddress?.port else {
            return XCTFail("couldn't get port from \(String(reflecting: server.localAddress))")
        }
        try await WebSocket.connect(scheme: "ws", host: "localhost", port: port, on: self.elg) { (ws) async in
            do { try await ws.send("hello") } catch { promise.fail(error); try? await ws.close() }
            ws.onText { ws, _ in
                promise.succeed(())
                do { try await ws.close() } catch { XCTFail("Failed to close websocket: \(String(reflecting: error))") }
            }
        }
        try await promise.futureResult.get()
        try await server.close(mode: .all)
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
