import NIOWebSocket
import Foundation

#if compiler(>=5.5)
import _NIOConcurrency

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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
}
#endif
