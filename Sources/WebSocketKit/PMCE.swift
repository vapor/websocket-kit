import NIOHTTP1
import NIOWebSocket
import CompressNIO
import NIO
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import Logging

/// The PMCE class provides methods for exchanging compressed and decompressed frames following RFC 7692.
public final class PMCE: Sendable {
    
    /// Configures sending and receiving compressed data with DEFLATE as outline in RFC 7692.
    public struct PMCEConfig: Sendable {
        
        private static let logger = Logger(label: "PMCEConfig")
        
        public struct DeflateConfig: Sendable {
            
            public struct AgreedParameters:Sendable {
                /// Whether the server reuses the compression window acorss messages (takes over context) or not.
                public let takeover: ContextTakeoverMode
                
                /// The max size of the window in bits.
                public let maxWindowBits: UInt8?
                
                public init(
                    takeover: ContextTakeoverMode = .takeover,
                    maxWindowBits: UInt8? = 15
                ) {
                    self.takeover = takeover
                    self.maxWindowBits = maxWindowBits
                }
                
            }
            
            /// Configures zlib with more granularity.
            public struct ZlibConf: CustomDebugStringConvertible, Sendable {
                
                public var debugDescription: String {
                    "ZlibConf{\(memLevel), \(compressionLevel)}"
                }
                
                /// Convenience members for common combinations of resource allocation.
                public static let maxRamMaxComp:ZlibConf = .init(memLevel: 9, compLevel: 9)
                public static let maxRamMidComp:ZlibConf = .init(memLevel: 9, compLevel: 5)
                public static let maxRamMinComp:ZlibConf = .init(memLevel: 9, compLevel: 1)
                
                public static let midRamMinComp:ZlibConf = .init(memLevel: 5, compLevel: 1)
                public static let midRamMidComp:ZlibConf = .init(memLevel: 5, compLevel: 5)
                public static let midRamMaxComp:ZlibConf = .init(memLevel: 5, compLevel: 9)
                
                public static let minRamMinComp:ZlibConf = .init(memLevel: 1, compLevel: 5)
                public static let minRamMidComp:ZlibConf = .init(memLevel: 1, compLevel: 1)
                public static let minRamMaxComp:ZlibConf = .init(memLevel: 1, compLevel: 9)

                /// Common combinations of memory and compression allocation.
                public static func commonConfigs() -> [ZlibConf] {
                    [
                       midRamMaxComp, midRamMidComp, midRamMinComp,
                       minRamMaxComp, minRamMinComp, minRamMinComp,
                       maxRamMaxComp, maxRamMidComp, maxRamMinComp
                    ]
                }
                
                public static func defaultConfig() -> ZlibConf {
                    .midRamMidComp
                }
                public var memLevel:Int32
                
                public var compressionLevel:Int32
                
                public init(memLevel:Int32, compLevel:Int32) {
                    assert( (-1...9).contains(compLevel),
                            "compLevel must be -1(default)...9 ")
                    assert( (1...9).contains(memLevel),
                            "memLevel must be 1...9 ")
                    self.memLevel = memLevel
                    self.compressionLevel = compLevel
                }
            }
            
            /// These are negotiated.
            public let agreedParams:AgreedParameters
            
            /// Zlib options not found in RFC-7692 for deflate can be passed in by the initialing side..
            public let zlibConfig:ZlibConf

            public init(agreedParams:AgreedParameters,
                        zlib:ZlibConf = .midRamMidComp) {
                
                assert((9...15).contains(agreedParams.maxWindowBits!),
                       "Window size must be between the values 9 and 15")
               
                self.agreedParams = agreedParams
                self.zlibConfig = zlib
            }
        }
       
        private static let _logging:NIOLockedValueBox<Bool> = .init(true)
        
        /// Enables some logging since I dont have a Logger.
        public static var logging:Bool {
            get {
                _logging.withLockedValue { v in
                    v
                }
            }
            set {
                _logging.withLockedValue { v in
                    v = newValue
                }
            }
        }
        
        /// Identifies this extension per RFC-7692.
        public static let pmceName = "permessage-deflate"
        
        /// Represents the states for using the same compression window across messages or not.
        public enum ContextTakeoverMode:String, Codable, CaseIterable, Sendable {
            case takeover
            case noTakeover
        }
        
        /// Holds the  config.
        public let deflateConfig:DeflateConfig
        
        private typealias ConfArgs = (sto:ContextTakeoverMode,
                                      cto: ContextTakeoverMode,
                                      sbits: UInt8?,
                                      cbits: UInt8?)
        
        public typealias ClientServerPMCEConfig = (client:PMCEConfig?,
                                                   server:PMCEConfig?)

        /// Will init an array of ClientServerConfigs from parsed header values if possible.
        public static func configsFrom(headers:HTTPHeaders) -> [ClientServerPMCEConfig] {
            if logging {
                logger.trace("getting configs from \(headers) ...")
            }
            
            if let wsx = headers.first(name: wsxtHeader)
            {
                return offers(in: wsx).compactMap({config(from: $0)})
            }
            else {
                if logging {
                    logger.trace("no configs found ...")
                }
                return []
            }
        }
        
        private static func offers(in headerValue: String) -> [Substring] {
            logger.trace("headerValue \(headerValue)")
            return headerValue.split(separator: ",")
        }
        
        private static func config(from offer: Substring) -> ClientServerPMCEConfig {

            // settings in an offer are split with ;
            // You will need to add a dependency on https://github.com/apple/swift-algorithms.git for this.
            let settings = offer
                .split(separator:";")
                .map { $0.trimmingPrefix(\.isWhitespace).trimmingSuffix(\.isWhitespace) }
                .filter { $0 != "permessage-deflate" }
            
            var arg = ConfArgs(.takeover, .takeover, nil, nil)
            
            for setting in settings {
                arg = self.arg(from: setting,
                               into: &arg)
            }
            logger.trace("Offer \(offer) arg \(arg)")
            
            let agreedClient = DeflateConfig.AgreedParameters(takeover:  arg.cto,
                                                maxWindowBits: arg.cbits ?? 15)
                
            let agreedServer = DeflateConfig.AgreedParameters(takeover: arg.sto,
                                                maxWindowBits: arg.sbits ?? 15)
            
          
            
            return (client:PMCEConfig(config: DeflateConfig(agreedParams: agreedClient,
                                                     zlib: .midRamMidComp)),
                    server:PMCEConfig(config: DeflateConfig(agreedParams: agreedServer,
                                                     zlib: .midRamMidComp)) )
        }
        
        private static func arg(from setting:Substring,
                                into foo:inout ConfArgs) -> ConfArgs {
            
            let splits = setting.split(separator:"=")
            
            if let first = splits.first {
                let sane = first.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.trace("sane = \(sane)")
                if trimmedName == DeflateHeaderParams.cmwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.replacing("\"", with: "")
                                                               with: "")
                        foo.cbits = UInt8(trimmed)
                    }
                    else
                    {
                        if logging {
                            PMCEConfig.logger.trace("no arg for cmwb")
                        }
                    }
                    
                }
                else if first == DeflateHeaderParams.smwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.sbits = UInt8(trimmed) ?? nil
                    }
                    else
                    {
                        if logging {
                            PMCEConfig.logger.trace("no arg for smwb")
                        }
                    }
                }
                else if sane == DeflateHeaderParams.cnct {
                    foo.cto = .noTakeover
                }
                else if sane == DeflateHeaderParams.snct {
                    foo.sto = .noTakeover
                }
                else if first == PMCE.PMCEConfig.pmceName {
                    if logging {
                        PMCEConfig.logger.error("oops something didnt parse in \(setting).")
                    }
                }
                else {
                    if logging {
                        PMCEConfig.logger.trace("unrecognized first split from setting \(setting). Maybe the header is malformed ?")
                    }
                }
            }
            else {
                
                PMCEConfig.logger.error("couldnt parse arg; no first split @ =. Maybe header is malformed.")
            }
            return foo
        }
        
        /// Defines the strings for headers parameters from RFC.
        public enum DeflateHeaderParams {
            // applies to client compressor, server decompressor
            static let cnct = "client_no_context_takeover"
            // applies to server compressor, client decompressor
            static let snct = "server_no_context_takeover"
            // applies to client compressor, server decompressor
            static let cmwb = "client_max_window_bits"
            // applies to server compressor, client decompressor
            static let smwb = "server_max_window_bits"
        }
        
        /// Creates a new PMCE config.
        ///  config : a DeflateConfig
        public init(config: DeflateConfig) {
            self.deflateConfig = config
        }
        
        /// Creates HTTPHeaders to represent this config.
        /// RFC 7692 has more detailed infofrmation.
        public func headers() -> HTTPHeaders {
            
            let params = headerParams(isQuoted: false)
            return [PMCE.wsxtHeader : PMCE.PMCEConfig.pmceName + (params.isEmpty ? "" : ";" + params)]
            
        }
                
        private func headerParams(isQuoted:Bool = false) -> String {
            let q = isQuoted ? "\"" : ""
            var components: [String] = []
            
            if deflateConfig.agreedParams.takeover == .noTakeover {
                components += [DeflateHeaderParams.cnct, DeflateHeaderParams.snct]
            }
            
            if let mwb = deflateConfig.agreedParams.maxWindowBits {
                components += [
                    "\(DeflateHeaderParams.cmwb)=\(q)\(mwb)\(q)",
                    "\(DeflateHeaderParams.smwb)=\(q)\(mwb)\(q)",
                ]
            }
            
            return components.joined(separator: ";")
        }
        
     
    }
        
    /// Uses config options to determine if the compressor or decompressor context should be reused (taken over) or reset after each message.
    public func shouldTakeOverContext() -> Bool {
        
        switch extendedSocketType {
        case .server:
            return serverConfig.deflateConfig.agreedParams.takeover == .takeover

        case .client:
            return clientConfig.deflateConfig.agreedParams.takeover == .takeover

        }
    }
    
    /// Header name to contain PMCE settings as defined in RFC-7692.
    public static let wsxtHeader = "Sec-WebSocket-Extensions"
    
    /// Tells PMCE how to apply the DEFLATE config as well as how to extract per RFC-7692.
    public let extendedSocketType:WebSocket.PeerType
    
    /// The channel whose allocator to use for the compression ByteBuffers and  box event loops.
    public let channel:NIO.Channel?
    
    /// Enables/disables logging.
    public var logging:Bool {
        get {
            _logging.withLockedValue { v in
                v
            }
        }
        set {
            _logging.withLockedValue { v in
                v = newValue
            }
        }
    }

    //this may be deprecated will drive it out in tests hopefully
    /// prett sure the new init flows means this isnt requried. it was a first attempt when things were still more mixed up and less SRP.
    /// This allows a server socket that has PMCE available to optionaly use it or not; So a compressed server can still talk uncompressed.
    public var enabled:Bool {
        get {
            _enabled.withLockedValue { v in
                v
            }
        }
        set {
            _enabled.withLockedValue { v in
                v = newValue
                logger.debug("enabled: \(v)")
            }
        }
    }

    /// Represents the strategy of pmce used with the server.
    public let serverConfig: PMCEConfig
    
    /// Represents the strategy of pmce used with the client.
    public let clientConfig: PMCEConfig
    
    ///  Registers a callback to be called when a TEXT frame arrives.
    /// - Parameters:
    ///   - clientConfig: PMCE cofiguration for the client side.
    ///   - serverConfig: PMCE configuration for the server side.
    ///   - peerType: The peer role of the socket this PMCE will be used wtth.
    ///   - channel: The channel whose allocation is used for comp/decomp streams.
    ///
    /// - returns: Initialized PMCE.
    public init(clientConfig: PMCEConfig,
                serverConfig: PMCEConfig,
                channel: Channel,
                peerType: WebSocket.PeerType) {
        
        self.clientConfig = clientConfig
        self.serverConfig = serverConfig
        
        self.channel = channel
        self.extendedSocketType = peerType
        
        self._enabled = NIOLockedValueBox(true)
        self._logging = NIOLockedValueBox(true)
        
       

        switch extendedSocketType {
        case .server:
            logger.trace("server")

            let winSize = PMCE.sizeFor(bits: serverConfig.deflateConfig.agreedParams.maxWindowBits ?? 15)
            logger.trace("window size: \(winSize)")
            
            let zscConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: serverConfig.deflateConfig.zlibConfig.compressionLevel,
                                            memoryLevel: serverConfig.deflateConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)
            
            let zsdConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: serverConfig.deflateConfig.zlibConfig.compressionLevel,
                                            memoryLevel: serverConfig.deflateConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)
            self.compressorBox = NIOLoopBoundBox(CompressionAlgorithm.deflate(configuration: zscConf).compressor,
                                                 eventLoop: channel.eventLoop)
            self.decompressorBox = NIOLoopBoundBox(CompressionAlgorithm.deflate(configuration: zsdConf).decompressor,
                                                   eventLoop: channel.eventLoop)
            logger.trace("compressor \(zscConf)")
            logger.trace("decompressor \(zsdConf)")
            
        case .client:
            logger.trace("client")

            let winSize = PMCE.sizeFor(bits: clientConfig.deflateConfig.agreedParams.maxWindowBits ?? 15)
            logger.trace("window size: \(winSize)")

            let zccConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: clientConfig.deflateConfig.zlibConfig.compressionLevel,
                                            memoryLevel: clientConfig.deflateConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)
            
            let zcdConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: clientConfig.deflateConfig.zlibConfig.compressionLevel,
                                            memoryLevel: clientConfig.deflateConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)

            self.compressorBox = NIOLoopBoundBox(CompressionAlgorithm.deflate(configuration: zccConf).compressor,
                                                 eventLoop: channel.eventLoop)
            
            self.decompressorBox = NIOLoopBoundBox( CompressionAlgorithm.deflate(configuration: zcdConf).decompressor,
                                             eventLoop: channel.eventLoop)
            
            logger.trace("compressor \(zccConf)")
            logger.trace("decompressor \(zcdConf)")
        }
        startStreams()
    }
    
    ///  Starts compress-nio streams for DEFLATE support.
    /// - returns: Void
    public func startStreams() {
        do {
            try compressorBox.value?.startStream()
        }
        catch {
            logger.error("error starting compressor stream : \(error)")
        }
        do {
            try decompressorBox.value?.startStream()
        }
        catch {
            logger.error("error starting decompressor stream : \(error)")
        }
    }
    
    ///  Stops compress-nio streams for DEFLATE support.
    /// - returns: Void
    public func stopStreams() {
        do {
            logger.debug("PMCE: stopping compressor stream...")
            try compressorBox.value?.finishStream()
        }
        catch {
            logger.error("PMCE:error finishing stream(s) : \(error)")
        }
        
        do {
            logger.debug("PMCE: stopping decompressor stream...")
            try decompressorBox.value?.finishStream()
        }
        catch {
            logger.error("PMCE:error finishing stream(s) : \(error)")
        }
        

    }

    /// websocket send calls this to compress.
    public func compressed(_ buffer: ByteBuffer,
                            fin: Bool = true,
                            opCode: WebSocketOpcode = .binary) throws -> WebSocketFrame {
        
        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "PMCE: channel not configured.")
        }
        let notakeover = !shouldTakeOverContext()

        let startSize = buffer.readableBytes
        
        if logging {
            logger.trace("compressing \(startSize) bytes for \(opCode)")
        }
        do {
            var mutBuffer = buffer

            if !notakeover {
                mutBuffer = unpad(buffer:buffer)
            }

            let startTime = Date()
            
            let compressed =
            try mutBuffer.compressStream(with: compressorBox.value!,
                                         flush: .sync,
                                         allocator: channel.allocator)
            if logging {
                let endTime = Date()
                let endSize = compressed.readableBytes
                
                logger.trace("compressed \(startSize) to \(endSize) bytes @ \(startSize / endSize) ratio from")
                switch extendedSocketType {
                case .server:
                    logger.trace(" \(serverConfig.deflateConfig.zlibConfig)")
                case .client:
                    logger.trace(" \(clientConfig.deflateConfig.zlibConfig)")
                }
                
                logger.trace("in \(startTime.distance(to: endTime))")
            }
            
            if notakeover {
                logger.trace("resetting compressor stream")
                try compressorBox.value?.resetStream()
            }else {
            }
            
            var frame = WebSocketFrame(
                fin: true,
                opcode: opCode,
                maskKey: self.makeMaskKey(),
                data: compressed
            )
            
            frame.rsv1 = true // denotes compression
            let slice = compressed.getSlice(at:compressed.readerIndex,
                                                         length: compressed.readableBytes - 4)
            frame.data = slice ?? compressed

            return frame
        }
        catch {
            logger.error("PMCE: send compression failed \(error)")
        }
        
    }

    /// Websocket calls  from handleIncoming to decompress.
    public func decompressed(_ frame: WebSocketFrame) throws -> WebSocketFrame  {

        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "PMCE: channel not configured.")
        }
        let takeover = shouldTakeOverContext()

        let startTime = Date()
        
        
        var data = frame.data
        let startSize = data.readableBytes
        if logging {
            logger.trace("PMCE: decompressing  \(startSize) bytes for \(frame.opcode)")
        }
        logger.trace("PMCE: config: \(serverConfig) \(clientConfig)")
        
        if takeover {
            data = pad(buffer:data)
        }

        let decompressed =
        try data.decompressStream(with: self.decompressorBox.value!,
                                  maxSize: .max,
                                  allocator: channel.allocator)
        if logging {
            let endTime = Date()
            
            let endSize = decompressed.readableBytes
            
            logger.trace("deompressed \(startSize) to \(endSize) bytes @ \(endSize/startSize) ratio from")
            logger.trace(" \(serverConfig.deflateConfig.zlibConfig) \(clientConfig.deflateConfig.zlibConfig)")

            
            logger.trace("in \(startTime.distance(to: endTime))")
        }
        
        if !takeover {
            if logging { logger.trace("PMCE: resetting decompressoer stream.") }
            try decompressorBox.value?.resetStream()
        }else {
            if logging { logger.trace("PMCE: not restting decompressor stream.")}
        }
        
        let newFrame = WebSocketFrame(fin: frame.fin,
                                      rsv1: false,
                                      rsv2: frame.rsv2,
                                      rsv3: frame.rsv3,
                                      opcode: frame.opcode,
                                      maskKey: frame.maskKey,
                                      data: decompressed,
                                      extensionData: nil)
        return newFrame
    }

    /// Server decomp uses this as RFC-7692 says client must mask msgs but server must not.
    public func unmasked(frame maskedFrame: WebSocketFrame) -> WebSocketFrame {
        logger.trace("PMCE: unmasking \(maskedFrame)")
        guard let key = maskedFrame.maskKey else {
            logger.trace("PMCE: tried to unmask a frame that isnt already masked.")
            return maskedFrame
        }
        
        var unmaskedData = maskedFrame.data
        unmaskedData.webSocketUnmask(key)
        return WebSocketFrame(fin: maskedFrame.fin,
                              rsv1: maskedFrame.rsv1,
                              rsv2: maskedFrame.rsv2,
                              rsv3: maskedFrame.rsv3,
                              opcode: maskedFrame.opcode,
                              maskKey: nil,
                              data: unmaskedData,
                              extensionData: maskedFrame.extensionData)
    }

    ///
    private let logger = Logger(label: "PMCE")
    private let _logging:NIOLockedValueBox<Bool>
    private let _enabled:NIOLockedValueBox<Bool>

    // Converts windowBits to size of window.
    private static func sizeFor(bits:UInt8) -> Int32 {
        2^Int32(bits)
    }
    
    private func pad(buffer:ByteBuffer) -> ByteBuffer {
        logger.trace("padding buffer with \(paddingOctets)")
        var mutbuffer = buffer
        mutbuffer.writeBytes(paddingOctets)
        return mutbuffer
    }

    private func unpad(buffer:ByteBuffer) -> ByteBuffer {
        logger.trace("unpadding \(buffer)")
        return buffer.getSlice(at: 0, length: buffer.readableBytes - 4) ?? buffer
    }
    
    // client compression uses this
    private func makeMaskKey() -> WebSocketMaskingKey? {
        switch extendedSocketType {
        
        case .client:
            let mask = WebSocketMaskingKey.random()
            logger.trace("PMCE: created mask key \(mask) .")
            return mask
        case .server:
            logger.trace("PMCE: mask key is nil due to extending server socket type.")
            return nil
        }
    }
    
    // Box for compressor to conform to Sendable.
    private let compressorBox:NIOLoopBoundBox<NIOCompressor?>
    
    // 4 bytes used for compress and decompress when context takeover is being used.
    private let paddingOctets:[UInt8] = [0x00, 0x00, 0xff, 0xff]

    // Box for compressor to conform to Sendable.
    private let decompressorBox:NIOLoopBoundBox<NIODecompressor?>
    
    // sometimes see internalError when server gets ctrl-c'd. I think it is related to the issues Ive seeen with stopping the server in general via ctrl-c.
    deinit {
       stopStreams()
    }
    
}

// any ideas to make it prettier or even add colors are welcome, reviiewers.
extension PMCE: CustomStringConvertible {
    public var description: String {
        """
        enabled : \(enabled),
        extendedSocketType : \(self.extendedSocketType),
        serverConfig : \(serverConfig),
        clientConfig : \(clientConfig)
        """
    }
}

extension PMCE.PMCEConfig: Equatable {
    public static func == (lhs: PMCE.PMCEConfig,
                           rhs: PMCE.PMCEConfig) -> Bool {
        return lhs.headerParams() == rhs.headerParams()
    }
}

extension PMCE.PMCEConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "PMCEConfig {config:\(deflateConfig)}"
    }
}

extension PMCE.PMCEConfig: CustomStringConvertible {
    public var description: String {
        """
        PMCEConfig {
          \(self.deflateConfig.debugDescription)
        }
        """
    }
}

extension PMCE.PMCEConfig.DeflateConfig: Equatable {
    
    public static func == (lhs: PMCE.PMCEConfig.DeflateConfig,
                           rhs: PMCE.PMCEConfig.DeflateConfig) -> Bool {
        return lhs.agreedParams.takeover == rhs.agreedParams.takeover &&
        lhs.agreedParams.maxWindowBits == rhs.agreedParams.maxWindowBits &&
        (lhs.zlibConfig.compressionLevel == rhs.zlibConfig.compressionLevel ) &&
        (lhs.zlibConfig.memLevel == rhs.zlibConfig.memLevel )
    }
    
}

extension PMCE.PMCEConfig.DeflateConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "DeflateConfig {agreedParams:\(agreedParams), zlib:\(zlibConfig)}"
    }
}

extension PMCE.PMCEConfig.DeflateConfig: CustomStringConvertible {
    public var description: String {
        """
        agreedParams : \(agreedParams),
        zlib : \(zlibConfig)
        """
    }
}
