import NIOWebSocket
import Foundation

#if compiler(>=5.5)
import _NIOConcurrency

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension WebSocket {
    public func send<S>(_ text: S) async throws
        where S: Collection, S.Element == Character
    {
        let promise = eventLoop.makePromise(of: Void.self)
        send(text, promise: promise)
        return try await promise.futureResult.get()
    }

    public func send(_ binary: [UInt8]) async throws {
        try await send(raw: binary, opcode: .binary, fin: true)
    }

    public func sendPing() async throws {
        try await send(raw: Data(), opcode: .ping, fin: true)
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

    public func onText(_ callback: @escaping (WebSocket, String) async -> ()) {
        onText { socket, text in
            Task {
                await callback(socket, text)
            }
        }
    }

    public func onBinary(_ callback: @escaping (WebSocket, ByteBuffer) async -> ()) {
        onBinary { socket, binary in
            Task {
                await callback(socket, binary)
            }
        }
    }

    public func onPong(_ callback: @escaping (WebSocket) async -> ()) {
        onPong { socket in
            Task {
                await callback(socket)
            }
        }
    }

    public func onPing(_ callback: @escaping (WebSocket) async -> ()) {
        onPing { socket in
            Task {
                await callback(socket)
            }
        }
    }
}
#endif
