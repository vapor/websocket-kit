#if swift(>=5.8)

@_documentation(visibility: internal) @_exported import struct NIOCore.ByteBuffer
@_documentation(visibility: internal) @_exported import protocol NIOCore.Channel
@_documentation(visibility: internal) @_exported import protocol NIOCore.EventLoop
@_documentation(visibility: internal) @_exported import protocol NIOCore.EventLoopGroup
@_documentation(visibility: internal) @_exported import struct NIOCore.EventLoopPromise
@_documentation(visibility: internal) @_exported import class NIOCore.EventLoopFuture
@_documentation(visibility: internal) @_exported import struct NIOHTTP1.HTTPHeaders
@_documentation(visibility: internal) @_exported import struct Foundation.URL

#else

@_exported import struct NIOCore.ByteBuffer
@_exported import protocol NIOCore.Channel
@_exported import protocol NIOCore.EventLoop
@_exported import protocol NIOCore.EventLoopGroup
@_exported import struct NIOCore.EventLoopPromise
@_exported import class NIOCore.EventLoopFuture
@_exported import struct NIOHTTP1.HTTPHeaders
@_exported import struct Foundation.URL

#endif
