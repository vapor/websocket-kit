import XCTest
import NIO
@testable import WebSocketKit

final class NIOWebSocketClientTests: XCTestCase {
    func testWebSocketEcho() throws {
        let webSocket = try WebSocket.connect(to: "ws://echo.websocket.org", on: elg).wait()
        webSocket.send("Hello")
        webSocket.onText { webSocket, string in
            print(string)
            XCTAssertEqual(string, "Hello")
            webSocket.close(promise: nil)
        }
        try webSocket.onClose.wait()
    }

    func testBadHost() throws {
        XCTAssertThrowsError(try WebSocket.connect(host: "asdf", on: elg).wait())
    }

    var elg: EventLoopGroup!
    override func setUp() {
        self.elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    override func tearDown() {
        try! self.elg.syncShutdownGracefully()
    }
}
