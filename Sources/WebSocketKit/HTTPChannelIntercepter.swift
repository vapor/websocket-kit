//
//  File.swift
//  
//
//  Created by Matthaus Woolard on 26/01/2021.
//

import Foundation
import NIOHTTP1
import NIO

public final class HTTPChannelIntercepter: ChannelDuplexHandler, RemovableChannelHandler {
    
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTPClientRequestPart

    public typealias InboundIn = HTTPClientResponsePart
    public typealias InboundOut = HTTPClientResponsePart
    
    let writeInterceptHandler: (HTTPRequestHead) -> Void
    
    public init(writeInterceptHandler: @escaping (HTTPRequestHead) -> Void) {
        self.writeInterceptHandler = writeInterceptHandler
    }
    
    public func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let interceptedOutgoingRequest = self.unwrapOutboundIn(data)
        
        if case .head(let requestHead) = interceptedOutgoingRequest {
            self.writeInterceptHandler(requestHead)
        }
        
        context.write(data, promise: promise)
    }
}

extension ChannelPipeline {
    public func addHTTPClientHandlers(
        position: Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        withServerUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil,
        withExtraHandlers extraHandlers: [RemovableChannelHandler] = []
    ) -> EventLoopFuture<Void> {
        let requestEncoder = HTTPRequestEncoder()
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
        
        var handlers: [RemovableChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder)] + extraHandlers
        
        if let (upgraders, completionHandler) = upgrade {
            let upgrader = NIOHTTPClientUpgradeHandler(
                upgraders: upgraders,
                httpHandlers: handlers,
                upgradeCompletionHandler: completionHandler
            )
            handlers.append(upgrader)
        }

        return self.addHandlers(handlers, position: position)
    }
}
