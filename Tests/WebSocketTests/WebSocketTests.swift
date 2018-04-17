import WebSocket
import XCTest

class WebSocketTests: XCTestCase {
    func testServer() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)

        let ws = WebSocket.httpProtocolUpgrader(shouldUpgrade: { req in
            if req.url.path == "/deny" {
                return nil
            }
            return [:]
        }, onUpgrade: { ws, req in
            ws.send(req.url.path)
            ws.onText { ws, string in
                ws.send(string.reversed())
                if string == "close" {
                    ws.close()
                }
            }
            ws.onData { ws, data in
                print("data: \(data)")
            }
            ws.onClose { ws in
                print("closed")
            }
        })

        struct HelloResponder: HTTPServerResponder {
            func respond(to request: HTTPRequest, on worker: Worker) -> EventLoopFuture<HTTPResponse> {
                let res = HTTPResponse(status: .ok, body: HTTPBody(string: "Hello, world!"))
                return Future.map(on: worker) { res }
            }
        }

        let server = try HTTPServer.start(
            hostname: "127.0.0.1",
            port: 8888,
            responder: HelloResponder(),
            upgraders: [ws],
            on: group
        ) { error in
            XCTFail("\(error)")
        }.wait()

        print(server)
        // uncomment to test websocket server
        try server.onClose.wait()
    }


    static let allTests = [
        ("testServer", testServer),
    ]
}
