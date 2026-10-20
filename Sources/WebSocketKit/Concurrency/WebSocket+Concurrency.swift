import NIOCore
import NIOWebSocket
import Foundation
import NIOHTTP1

extension WebSocket {
    public func send<S>(_ text: S) async throws
        where S: Collection, S.Element == Character
    {
        let promise = eventLoop.makePromise(of: Void.self)
        send(text, promise: promise)
        return try await promise.futureResult.get()
    }

    public func send(_ binary: [UInt8]) async throws {
        let promise = eventLoop.makePromise(of: Void.self)
        send(binary, promise: promise)
        return try await promise.futureResult.get()
    }

    public func sendPing() async throws {
        try await sendPing(Data())
    }

    public func sendPing(_ data: Data) async throws {
        let promise = eventLoop.makePromise(of: Void.self)
        sendPing(data, promise: promise)
        return try await promise.futureResult.get()
    }

    public func send<Data>(
        raw data: Data,
        opcode: WebSocketOpcode,
        fin: Bool = true
    ) async throws
        where Data: DataProtocol
    {
        let promise = eventLoop.makePromise(of: Void.self)
        send(raw: data, opcode: opcode, fin: fin, promise: promise)
        return try await promise.futureResult.get()
    }

    public func close(code: WebSocketErrorCode = .goingAway) async throws {
        try await close(code: code).get()
    }

    @preconcurrency public func onText(_ callback: @Sendable @escaping (WebSocket, String) async -> ()) {
        self.eventLoop.execute {
            self.onText { socket, text in
                Task {
                    await callback(socket, text)
                }
            }
        }
    }

    @preconcurrency public func onBinary(_ callback: @Sendable @escaping (WebSocket, ByteBuffer) async -> ()) {
        self.eventLoop.execute {
            self.onBinary { socket, binary in
                Task {
                    await callback(socket, binary)
                }
            }
        }
    }

    public func onPong(_ callback: @Sendable @escaping (WebSocket, ByteBuffer) async -> ()) {
        self.eventLoop.execute {
            self.onPong { socket, data in
                Task {
                    await callback(socket, data)
                }
            }
        }
    }
    
    @available(*, deprecated, message: "Please use `onPong { socket, data in /* … */ }` with the additional `data` parameter.")
    @preconcurrency public func onPong(_ callback: @Sendable @escaping (WebSocket) async -> ()) {
        self.eventLoop.execute {
            self.onPong { socket, _ in
                Task {
                    await callback(socket)
                }
            }
        }
    }

    public func onPing(_ callback: @Sendable @escaping (WebSocket, ByteBuffer) async -> ()) {
        self.eventLoop.execute {
            self.onPing { socket, data in
                Task {
                    await callback(socket, data)
                }
            }
        }
    }
    
    @available(*, deprecated, message: "Please use `onPing { socket, data in /* … */ }` with the additional `data` parameter.")
    @preconcurrency public func onPing(_ callback: @Sendable @escaping (WebSocket) async -> ()) {
        self.eventLoop.execute {
            self.onPing { socket, _ in
                Task {
                    await callback(socket)
                }
            }
        }
    }

    @preconcurrency public static func connect(
        to url: String,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: any EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) async -> ()
    ) async throws {
        return try await self.connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: { ws in
                Task {
                    await onUpgrade(ws)
                }
            }
        ).get()
    }

    @preconcurrency public static func connect(
        to url: URL,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: any EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) async -> ()
    ) async throws {
        return try await self.connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: { ws in
                Task {
                    await onUpgrade(ws)
                }
            }
        ).get()
    }

    @preconcurrency public static func connect(
        scheme: String = "ws",
        host: String,
        port: Int = 80,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: any EventLoopGroup,
        onUpgrade: @Sendable @escaping (WebSocket) async -> ()
    ) async throws {
        return try await self.connect(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            query: query,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: { ws in
                Task {
                    await onUpgrade(ws)
                }
            }
        ).get()
    }

    /// Establish a WebSocket connection, receiving the server's upgrade response headers.
    ///
    /// - Parameters:
    ///   - to: URL for the WebSocket server.
    ///   - headers: Headers to send to the WebSocket server.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgradeWithResponse: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`, invoked with the 101 Switching Protocols response head.
    @preconcurrency public static func connect(
        to url: String,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: any EventLoopGroup,
        onUpgradeWithResponse: @Sendable @escaping (WebSocket, HTTPResponseHead) async -> ()
    ) async throws {
        return try await self.connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgradeWithResponse: { ws, head in
                Task {
                    await onUpgradeWithResponse(ws, head)
                }
            }
        ).get()
    }

    /// Establish a WebSocket connection, receiving the server's upgrade response headers.
    ///
    /// - Parameters:
    ///   - to: URL for the WebSocket server.
    ///   - headers: Headers to send to the WebSocket server.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgradeWithResponse: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`, invoked with the 101 Switching Protocols response head.
    @preconcurrency public static func connect(
        to url: URL,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: any EventLoopGroup,
        onUpgradeWithResponse: @Sendable @escaping (WebSocket, HTTPResponseHead) async -> ()
    ) async throws {
        return try await self.connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgradeWithResponse: { ws, head in
                Task {
                    await onUpgradeWithResponse(ws, head)
                }
            }
        ).get()
    }

    /// Establish a WebSocket connection, receiving the server's upgrade response headers.
    ///
    /// - Parameters:
    ///   - scheme: Scheme component of the URI for the WebSocket server.
    ///   - host: Host component of the URI for the WebSocket server.
    ///   - port: Port on which to connect to the WebSocket server.
    ///   - path: Path component of the URI for the WebSocket server.
    ///   - query: Query component of the URI for the WebSocket server.
    ///   - headers: Headers to send to the WebSocket server.
    ///   - configuration: Configuration for the WebSocket client.
    ///   - eventLoopGroup: Event loop group to be used by the WebSocket client.
    ///   - onUpgradeWithResponse: An escaping closure to be executed after the upgrade is completed by `NIOWebSocketClientUpgrader`, invoked with the 101 Switching Protocols response head.
    @preconcurrency public static func connect(
        scheme: String = "ws",
        host: String,
        port: Int = 80,
        path: String = "/",
        query: String? = nil,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: any EventLoopGroup,
        onUpgradeWithResponse: @Sendable @escaping (WebSocket, HTTPResponseHead) async -> ()
    ) async throws {
        return try await self.connect(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            query: query,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgradeWithResponse: { ws, head in
                Task {
                    await onUpgradeWithResponse(ws, head)
                }
            }
        ).get()
    }
}
