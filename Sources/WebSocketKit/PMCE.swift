import NIOHTTP1
import NIOWebSocket
import CompressNIO
import NIO
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import Logging
	
public final class PMCE: Sendable {
    
    private let logger = Logger(label: "PMCE")
    
    /// Configures sending and receiving compressed data with DEFLATE.
    public struct PMCEConfig: Sendable {
        
        private static let logger = Logger(label: "PMCEConfig")
        
        public struct DeflateConfig: Sendable {
            
            public struct AgreedParameters:Sendable {
                /// Whether the server reuses the compression window acorss messages (takes over context) or not.
                public let takeover: ContextTakeoverMode
                
                /// The max size of the window in bits.
                public let maxWindowBits: UInt8?
                
                public init(takeover:ContextTakeoverMode? = .takeover,
                     maxWindowBits:UInt8? = 15) {
                    self.takeover = takeover!
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
                ///
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
            
            /// Zlib options not found in RFC-7692 for deflate.
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
        
        public typealias ClientServerPMCEConfig = (client:PMCEConfig?, server:PMCEConfig?)
        
        private var paddingOctets:[Int] {
             [0x00, 0x00, 0xff, 0xff].map({
                Int(bitPattern: $0)
             }
             )
        }

        /// Will init an array of ClientServerConfigs from parsed header values if possible.
        public static func configsFrom(headers:HTTPHeaders) -> [ClientServerPMCEConfig] {
            if logging {
                logger.trace("getting configs from \(headers)")
            }
            
            if let wsx = headers.first(name: wsxtHeader)
            {
                return offers(in: wsx).compactMap({config(from: $0)})
            }
            else {
                if logging {
                    PMCEConfig.logger.error("Tried to init a PMCE config with headers that do not contain the Sec-Websocket-Extensions key")
                }
                return [ClientServerPMCEConfig]()
            }
        }
        
        /// Finds pmce offers in a header value string.
        private static func offers(in headerValue:String) -> [Substring] {
            logger.trace("headerValue \(headerValue)")
            return headerValue.split(separator: ",")
        }
        
        /// Creates a config from an offer substring.
        private static func config(from offer: Substring) -> ClientServerPMCEConfig {

            // settings in an offer are split with ;
            let settings = offer.split(separator:";")
                                .filter({
                $0.trimmingCharacters(in: .whitespacesAndNewlines) !=
                                    "permessage-deflate"
            })
            
            var arg = ConfArgs(.takeover, .takeover, nil, nil)
            
            for (_,setting) in settings.enumerated() {
                let setting = setting
                arg = self.arg(from: setting,
                               into: &arg)
            }
            logger.trace("Offer \(offer)")
            logger.trace("arg \(arg)")
            
            let agreedClient = DeflateConfig.AgreedParameters(takeover:  arg.cto,
                                                maxWindowBits: arg.cbits ?? 15)
                
            let agreedServer = DeflateConfig.AgreedParameters(takeover: arg.sto,
                                                maxWindowBits: arg.sbits ?? 15)
            
          
            
            return (client:PMCEConfig(config: DeflateConfig(agreedParams: agreedClient,
                                                     zlib: .midRamMidComp)),
                    server:PMCEConfig(config: DeflateConfig(agreedParams: agreedServer,
                                                     zlib: .midRamMidComp)) )
        }
        
        /// Extracts the arg from a setting substring into foo returning foo.
        private static func arg(from setting:Substring,
                                into foo:inout ConfArgs) -> ConfArgs {
            
            let splits = setting.split(separator:"=")
            
            if let first = splits.first {
                let sane = first.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.trace("sane = \(sane)")
                if first == DeflateHeaderParams.cmwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.cbits = UInt8(trimmed) ?? nil
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
                else if first == "permessage-deflate" {
                    if logging {
                        PMCEConfig.logger.error("oops something didnt parse.")
                    }
                }
                else {
                    if logging {
                        PMCEConfig.logger.trace("unrecognized first split from setting \(setting)")
                    }
                }
            }
            else {
                
                PMCEConfig.logger.error("couldnt parse arg; no first split @ =")
            }
            return foo
        }
        
        /// Defines the strings for headers parameters from RFC.
        public struct DeflateHeaderParams {
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
        ///  PMCE config speccifies both sides of the exchange.
        /// clientCfg : a ClientConfig
        /// serverCfg: a ServerConfig
        public init(config: DeflateConfig,
                    logging:Bool  = false) {
            self.deflateConfig = config
        }
        
        /// Creates HTTPHeaders to represent this config.
        public func headers() -> HTTPHeaders {
            
            let params = headerParams(isQuoted: false)
            return [PMCE.wsxtHeader : PMCE.PMCEConfig.pmceName + (params.isEmpty ? "" : ";" + params)]
            
        }
                
        /// Creates header parameters for the Sec-WebSocket-Extensions header from the config.
        public func headerParams(isQuoted:Bool = false) -> String {
            var built = ""
            
            switch deflateConfig.agreedParams.takeover {
            case .noTakeover:
                built += DeflateHeaderParams.cnct + ";"
            case .takeover:
                built += ""
            }
            
            if deflateConfig.agreedParams.maxWindowBits != nil {
                built += DeflateHeaderParams.cmwb + (isQuoted ?
                                                     "=\"\(deflateConfig.agreedParams.maxWindowBits!)\"" :
                                                        "=\(deflateConfig.agreedParams.maxWindowBits!);")
            }
            
            switch deflateConfig.agreedParams.takeover {
            case .noTakeover:
                built += DeflateHeaderParams.snct + ";"
            case .takeover:
                built += ""
            }
            
            if deflateConfig.agreedParams.maxWindowBits != nil {
                
                built += DeflateHeaderParams.smwb + (isQuoted ?
                                                     "=\"\(deflateConfig.agreedParams.maxWindowBits!)\"" :
                                                        "=\(deflateConfig.agreedParams.maxWindowBits!);")
            }

            if built.last == ";" {
                let s = built.dropLast(1)
                return String(data: s.data(using: .utf8)!, encoding: .utf8)!
            }else {
                return built
            }
        }
        
     
    }
    
    /// MARK
    /// Uses config options to determine if context should be reused (taken over) or reset after each message.
    public func shouldTakeOverContext() -> Bool {
        var contextTakeOver = false
        
        switch extendedSocketType {
        case .server:
            return serverConfig.deflateConfig.agreedParams.takeover == .takeover

        case .client:
            return clientConfig.deflateConfig.agreedParams.takeover == .takeover

        }
        return contextTakeOver
    }
    
    /// PMCE settings are under this header as defined in RFC-7692.
    public static let wsxtHeader = "Sec-WebSocket-Extensions"
    
    // Box for compressor to conform to Sendable
    private let compressorBox:NIOLoopBoundBox<NIOCompressor?>
    
    // Box for compressor to conform to Sendable.
    private let decompressorBox:NIOLoopBoundBox<NIODecompressor?>
    
    /// Tells pmce how to apply the deflate config as well as how to extract per RFC-7692.
    public let extendedSocketType:WebSocket.PeerType
    
    /// The channel whose allocator to use for the compression bytebuffers and the box event loops.
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
    private let _logging:NIOLockedValueBox<Bool>

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
    private let _enabled:NIOLockedValueBox<Bool>

    // Converts windowBits to size of window.
    private static func sizeFor(bits:UInt8) -> Int32 {
        2^Int32(bits)
    }
  
    /// Represents the strategy of pmce used with the PMCE struct.
    /// Currentonly only permessage-deflate is supported.
    public let serverConfig: PMCEConfig
    public let clientConfig: PMCEConfig
    
    public init(clientConfig: PMCEConfig,
                serverConfig: PMCEConfig,
                channel: Channel,
                socketType: WebSocket.PeerType) {
        
        self.clientConfig = clientConfig
        self.serverConfig = serverConfig
        
        self.channel = channel
        self.extendedSocketType = socketType
        
        self._enabled = NIOLockedValueBox(true)
        self._logging = NIOLockedValueBox(true)
        
        // i think this is where the client comp configs the server decomp
        // and the server comp configs the client decomp
        logger.debug("extending ...")
        switch extendedSocketType {
        case .server:
            logger.debug("server")

            let winSize = PMCE.sizeFor(bits: serverConfig.deflateConfig.agreedParams.maxWindowBits ?? 15)
            logger.debug("window size: \(winSize)")
            
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
            logger.debug("compressor \(zscConf)")
            logger.debug("decompressor \(zsdConf)")
        case .client:
            logger.debug("client")

            let winSize = PMCE.sizeFor(bits: clientConfig.deflateConfig.agreedParams.maxWindowBits ?? 15)
            logger.debug("window size: \(winSize)")

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
            
            logger.debug("compressor \(zccConf)")
            logger.debug("decompressor \(zcdConf)")
        }
        startStreams()
    }
    
    /// Starts the compress-nio streams.
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
    
    /// Stops the compress-nio streams.
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
            logger.debug("compressing \(startSize) bytes for \(opCode)")
        }
        do {
            var mutBuffer = buffer

            if !notakeover {
                // will pad
                logger.debug("SHOLD unpad payload")

                mutBuffer = unpad(buffer:buffer)
            }else {
                // will not pad
                logger.debug("shold not pad")
            }

            let startTime = Date()
            
            let compressed =
            try mutBuffer.compressStream(with: compressorBox.value!,
                                         flush: .sync,
                                         allocator: channel.allocator)
                                        //rfc says to strip padding word off compressed
            mutBuffer = unpad(buffer: mutBuffer)
            if logging {
                let endTime = Date()
                let endSize = compressed.readableBytes
                
                logger.debug("compressed \(startSize) to \(endSize) bytes @ \(startSize / endSize) ratio from")
                switch extendedSocketType {
                case .server:
                    logger.debug(" \(serverConfig.deflateConfig.zlibConfig)")
                case .client:
                    logger.debug(" \(clientConfig.deflateConfig.zlibConfig)")
                }
                
                logger.debug("in \(startTime.distance(to: endTime))")
            }
            
            if notakeover {
                logger.debug("resetting compressor stream")
                try compressorBox.value?.resetStream()
            }else {
                logger.debug("not resetting compressor stream.")
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
            if slice == nil {
                logger.debug("slice was nil")
            }else {
                logger.debug("slice is not nil") // if slice is alwys nil this code below is wrong and is likely misapplied padding compsenation that never gets called

            }
            frame.data = slice ?? compressed

            return frame
        }
        catch {
            logger.error("PMCE: send compression failed \(error)")
        }
        
        return WebSocketFrame(fin:fin, rsv1: false, opcode:opCode, data: buffer)
    }

/*
  An endpoint uses the following algorithm to decompress a message.

   1.  Append 4 octets of 0x00 0x00 0xff 0xff to the tail end of the
       payload of the message.

   2.  Decompress the resulting data using DEFLATE.   
  */
      /// websocket calls  from handleIncoming to decompress.
    public func decompressed(_ frame: WebSocketFrame) throws -> WebSocketFrame  {

        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "PMCE: channel not configured.")
        }
        let takeover = shouldTakeOverContext()

        let startTime = Date()
        
        
        var data = frame.data
        let startSize = data.readableBytes
        if logging {
            logger.debug("PMCE: decompressing  \(startSize) bytes for \(frame.opcode)")
        }
        logger.debug("PMCE: config: \(serverConfig) \(clientConfig)")
        
        if takeover {
            logger.debug("should unpad message")
            data = pad(buffer:data)
        }else {
            logger.debug("shold NOT unpad message")
        }

        let decompressed =
        try data.decompressStream(with: self.decompressorBox.value!,
                                  maxSize: .max,
                                  allocator: channel.allocator)
        if logging {
            let endTime = Date()
            
            let endSize = decompressed.readableBytes
            
            logger.debug("deompressed \(startSize) to \(endSize) bytes @ \(endSize/startSize) ratio from")
            logger.debug(" \(serverConfig.deflateConfig.zlibConfig) \(clientConfig.deflateConfig.zlibConfig)")

            
            logger.debug("in \(startTime.distance(to: endTime))")
        }
        
        if !takeover {
            if logging { logger.debug("PMCE: resetting decompressoer stream.") }
            try decompressorBox.value?.resetStream()
        }else {
            if logging { logger.debug("PMCE: not restting decompressor stream.")}
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

    public func pad(buffer:ByteBuffer) -> ByteBuffer {
        logger.debug("padding")
        var mutbuffer = buffer
        mutbuffer.writeBytes([0x00,0x00,0xFF,0xFF])
        return mutbuffer
    }

    public func unpad(buffer:ByteBuffer) -> ByteBuffer {
        logger.info("unpaddings")
        return buffer.getSlice(at: 0, length: buffer.readableBytes - 4) ?? buffer
    }
    /// websocket calls from handleIncoming as a server to handle client masked compressed frames. This was epxerimentally determined.
    @available(*, deprecated)
    public func unmaskedDecompressedUnamsked(frame: WebSocketFrame) throws -> WebSocketFrame {
        
        if logging {
            logger.debug("PMCE: unmaksing/decomp/unmasking frame \(frame.opcode) data...")
        }
        logger.debug("PMCE: unmaskedData \(frame.unmaskedData)")
        let unmaskedCompressedFrame = unmasked(frame: frame)
        logger.debug("PMCE: unmaksed frame .data \(unmaskedCompressedFrame.unmaskedData)")
        // decompression
        let maskedDecompressedFrame = try self.decompressed(unmaskedCompressedFrame)
        
        // 2nd unmask
        let unmaskedDecompressedFrame = unmasked(frame: maskedDecompressedFrame)
        
        // append this frame and update the sequence
        let newFrame = WebSocketFrame(fin: frame.fin,
                                      rsv1: false,
                                      rsv2: frame.rsv2,
                                      rsv3: frame.rsv3,
                                      opcode: frame.opcode,
                                      maskKey: frame.maskKey, // should this be nil
                                      data: unmaskedDecompressedFrame.data,
                                      extensionData: nil)
        return newFrame
    }
    
    // client compression uses this
    private func makeMaskKey() -> WebSocketMaskingKey? {
        switch extendedSocketType {
        
        case .client:
            let mask = WebSocketMaskingKey.random()
            logger.debug("PMCE: created mask key \(mask) .")
            return mask
        case .server:
            return nil
        }
    }
    
    // server decomp uses this as RFC-7692 says client must mask msgs but server must not.
    public func unmasked(frame maskedFrame: WebSocketFrame) -> WebSocketFrame {
        logger.debug("PMCE: unmasking \(maskedFrame)")
        guard let key = maskedFrame.maskKey else {
            logger.debug("PMCE: tried to unmask a frame that isnt already masked.")
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

    deinit {
       stopStreams()
    }
    
}

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
