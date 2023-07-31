import NIOHTTP1
import NIOWebSocket
import CompressNIO
import NIO
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import Logging
	
/// I'd like to evenually abstract out a more general websocket extension interface.
public protocol PMCEZlibConfiguration: Codable, Equatable,
                                       Sendable, CustomDebugStringConvertible  {
    var memLevel:Int32 {get set}
    var compressionLevel:Int32 {get set}
}

public final class PMCE:Sendable {
    
    private let logger = Logger(label: "PMCE")
    
    /// Configures sending and receiving compressed data with DEFLATE.
    public struct DeflateConfig: Sendable {
        private static let logger = Logger(label: "PMCE")

        /// Configures the client side of deflate.
        public struct ClientConfig: Sendable {
            
            public let takeover: ContextTakeoverMode
            public let maxWindowBits: UInt8?
            public let zlibConfig: any PMCEZlibConfiguration

            public init(takeover:ContextTakeoverMode,
                        maxWindowBits:UInt8 = 15,
                        zlib:ZlibConf = .midRamMidComp) {
                
                assert((9...15).contains(maxWindowBits),
                       "Window size must be between the values 9 and 15")
                self.takeover = takeover
                self.maxWindowBits = maxWindowBits
                self.zlibConfig = zlib
            }
        }
        
        /// Configures the server side of deflate.
        public struct ServerConfig: Sendable {
            
            /// Whether the server reuses the compression window acorss messages (takes over context) or not.
            public let takeover: ContextTakeoverMode
            
            /// The max size of the window in bits.
            public let maxWindowBits: UInt8?
            
            /// Zlib options not found in RFC-7692 for deflate.
            public let zlibConfig: any PMCEZlibConfiguration

            public init(takeover:ContextTakeoverMode,
                        maxWindowBits:UInt8 = 15,
                        zlib:ZlibConf = .midRamMidComp) {
                
                assert((9...15).contains(maxWindowBits),
                       "Window size must be between the values 9 and 15")
                self.takeover = takeover
                self.maxWindowBits = maxWindowBits
                self.zlibConfig = zlib
            }
        }

        private static let _logging:NIOLockedValueBox<Bool> = .init(false)
        
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
        public enum ContextTakeoverMode:String, Codable, CaseIterable, Sendable
        {
            case takeover
            case noTakeover
        }
        
        /// Holds the client side config.
        public let clientConfig:ClientConfig
        
        /// Holds the server side config.
        public let serverConfig:ServerConfig
        
        private typealias ConfArgs = (sto:ContextTakeoverMode,
                                      cto: ContextTakeoverMode,
                                      sbits:UInt8?,
                                      cbits:UInt8?,
                                      sml:Int32?,
                                      cml:Int32?,
                                      scl:Int32?,
                                      ccl:Int32?)
        /// Will init an array of DeflateConfigs from parsed header values if possible.
        public static func configsFrom(headers:HTTPHeaders) -> [DeflateConfig] {
            if logging {
                logger.debug("getting configs from \(headers)")
            }
            if let wsx = headers.first(name: wsxtHeader) {
                
                let offers = offers(in:wsx)
                
                let requestedOfferConfigs = offers.compactMap({offer in
                        config(from:offer)
                    }
                )
                
                return requestedOfferConfigs
            
            }
            else {
                if logging {
                    DeflateConfig.logger.error("Tried to init a PMCE config with headers that do not contain the Sec-Websocket-Extensions key")
                }
                return [DeflateConfig]()
            }
        }
        
        /// Finds pmce offers in a header value string.
        private static func offers(in headerValue:String) -> [Substring] {
            headerValue.split(separator: ",")
        }
        
        /// Creates a config from an offer substring.
        private static func config(from offer:Substring) -> DeflateConfig? {

            // settings in an offer are split with ;
            let settings = offer.split(separator:";")
                                .filter({ setting in
                                    
                let filtered =  setting.trimmingCharacters(in: .whitespacesAndNewlines) !=
                                    "permessage-deflate"
                return filtered
            })
            
            var arg = ConfArgs(.takeover, .takeover, nil, nil, nil, nil, nil, nil)
            
            for (_,setting) in settings.enumerated() {
                let setting = setting
                arg = self.arg(from: setting, into: &arg)
            }
            
            let client = ClientConfig(takeover: arg.cto,
                                      maxWindowBits: arg.cbits ?? 15 )
            let server = ServerConfig(takeover: arg.sto,
                                      maxWindowBits: arg.sbits ?? 15)
            
            return DeflateConfig(clientCfg: client,
                                 serverCfg: server)
        }
        
        /// Extracts the arg from a setting substring into foo returning foo.
        private static func arg(from setting:Substring,
                                into foo:inout ConfArgs) -> ConfArgs {
            
            let splits = setting.split(separator:"=")
            
            if let first = splits.first {
                let sane = first.trimmingCharacters(in: .whitespacesAndNewlines)
               
                if first == DeflateHeaderParams.cmwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.cbits = UInt8(trimmed) ?? nil
                    }
                    else
                    {
                        if logging {
                            DeflateConfig.logger.debug("no arg for cmwb")
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
                            DeflateConfig.logger.debug("no arg for smwb")
                        }
                    }
                }
                else if sane == DeflateHeaderParams.cnct {
                    foo.cto = .noTakeover
                }
                else if sane == DeflateHeaderParams.snct {
                    foo.sto = .noTakeover
                }
                else if sane == ZlibHeaderParams.server_cmp_level {
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.scl = Int32(trimmed)
                    }
                    else
                    {
                        if logging {
                            DeflateConfig.logger.debug("no arg for server_cmp_level")
                        }
                    }
                }
                else if sane == ZlibHeaderParams.server_mem_level {
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                     
                        foo.sml = Int32(trimmed)
                    }
                    else
                    {
                        if logging {
                            DeflateConfig.logger.debug("no arg for server_mem_level")
                        }
                    }
                }else if sane == ZlibHeaderParams.client_cmp_level {
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.ccl = Int32(trimmed)
                    }
                    else
                    {
                        if logging {
                            DeflateConfig.logger.debug("no arg for server_cmp_level")
                        }
                    }
                }else if sane == ZlibHeaderParams.client_mem_level {
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.cml = Int32(trimmed)
                    }
                    else
                    {
                        if logging {
                            DeflateConfig.logger.debug("no arg for client_mem_level")
                        }
                    }
                }
                else if first == "permessage-deflate" {
                    if logging {
                        DeflateConfig.logger.error("oops something didnt parse.")
                    }
                }
                else {
                    if logging {
                        DeflateConfig.logger.debug("unrecognized first split from setting \(setting)")
                    }
                }
            }
            else {
                
                DeflateConfig.logger.error("couldnt parse arg; no first split @ =")
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
        
        /// Defines the strings for extended parameters not defined in the RFC.
        public struct ZlibHeaderParams {
            static let server_mem_level = "sml"
            static let server_cmp_level = "scl"
            static let client_mem_level = "cml"
            static let client_cmp_level = "ccl"
        }
        
        /// Creates a new PMCE config.
        ///  PMCE config speccifies both sides of the exchange.
        /// clientCfg : a ClientConfig
        /// serverCfg: a ServerConfig
        public init(clientCfg: ClientConfig,
                    serverCfg: ServerConfig,
                    logging:Bool  = false) {
            self.clientConfig = clientCfg
            self.serverConfig = serverCfg

        }
        
        /// Creates HTTPHeaders to represent this config.
        public func headers() -> HTTPHeaders {
            let params = headerParams(isQuoted: false)
            return [PMCE.wsxtHeader : PMCE.DeflateConfig.pmceName + (params.isEmpty ? "" : ";" + params)]
        }
        
        /// Creates header parameters for the Sec-WebSocket-Extensions header from the config.
        public func headerParams(isQuoted:Bool = false) -> String {
            var built = ""
            
            switch clientConfig.takeover {
            case .noTakeover:
                built += DeflateHeaderParams.cnct + ";"
            case .takeover:
                built += ""
            }
            
            if clientConfig.maxWindowBits != nil {
                built += DeflateHeaderParams.cmwb + (isQuoted ?
                                              "=\"\(clientConfig.maxWindowBits!)\"" :
                                                "=\(clientConfig.maxWindowBits!);")
            }
            
            switch serverConfig.takeover {
            case .noTakeover:
                built += DeflateHeaderParams.snct + ";"
            case .takeover:
                built += ""
            }
            
            if serverConfig.maxWindowBits != nil {
                
                built += DeflateHeaderParams.smwb + (isQuoted ?
                                              "=\"\(serverConfig.maxWindowBits!)\"" :
                                                "=\(serverConfig.maxWindowBits!);")
            }
                        
//            built += PMCE.DeflateConfig.ZlibHeaderParams.server_mem_level + " = " +
//            "\(serverConfig.zlibConfig.memLevel)" + ";"
//            
//            built += PMCE.DeflateConfig.ZlibHeaderParams.server_cmp_level + " = " +
//            "\(serverConfig.zlibConfig.compressionLevel)" + ";"
//            
//            built += PMCE.DeflateConfig.ZlibHeaderParams.client_mem_level + " = " +
//            "\(clientConfig.zlibConfig.memLevel)" + ";"
//            
//            built += PMCE.DeflateConfig.ZlibHeaderParams.client_cmp_level + " = " +
//            "\(clientConfig.zlibConfig.memLevel)" + ";"
            
            if built.last == ";" {
                let s = built.dropLast(1)
                return String(data: s.data(using: .utf8)!, encoding: .utf8)!
            }else {
                return built
            }
        }
        
        /// Uses config options to determine if context should be reused (taken over) or reset after each message.
        public func shouldTakeOverContext(isServer:Bool) -> Bool {
            var contextTakeOver = false
            
            switch isServer {
           
            case true:
                
                contextTakeOver = self.clientConfig.takeover == .takeover
                
            case false:
                contextTakeOver = self.serverConfig.takeover == .takeover
            }
            return contextTakeOver
        }
    }
    
    public struct ZlibConf: PMCEZlibConfiguration, CustomDebugStringConvertible {
        
        public var debugDescription: String {
            "ZlibConf{mem:\(memLevel), cmp:\(compressionLevel)}"
        }
        
        /// Convenience
        public static let maxRamMaxComp:ZlibConf = .init(memLevel: 9, compLevel: 9)
        public static let maxRamMinComp:ZlibConf = .init(memLevel: 9, compLevel: 1)
        
        public static let minRamMaxComp:ZlibConf = .init(memLevel: 1, compLevel: 9)
        public static let minRamMinComp:ZlibConf = .init(memLevel: 1, compLevel: 1)
        public static let midRamMidComp:ZlibConf = .init(memLevel: 5, compLevel: 5)
        
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
    
    /// PMCE settings are under this header as defined in RFC-7692.
    public static let wsxtHeader = "Sec-WebSocket-Extensions"
    
    /// Box for compressor to conform to Sendable
    private let compressorBox:NIOLoopBoundBox<NIOCompressor?>
    
    /// Box for compressor to conform to Sendable
    private let decompressorBox:NIOLoopBoundBox<NIODecompressor?>
    
    // Tells pmce how to apply the deflate config as well as how to extract per RFC-7692.
    public let extendedSocketType:WebSocket.PeerType
    
    // the channel whose allocator to use for compression bytebuffers and box event loops.
    public let channel:NIO.Channel?
    
    private let _logging:NIOLockedValueBox<Bool>
    
    /// Enables some logging since I dont have a Logger.
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
    
    private let _enabled:NIOLockedValueBox<Bool>
    
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
            }
        }
    }
    
    /// Converts windowBits to size of window.
    private static func sizeFor(bits:UInt8) -> Int32 {
        2^Int32(bits)
    }
  
    /// Represents the alg of pmce used with the PMCE struct.
    /// Currentonly only permessage-deflate is supported.
    public let config: DeflateConfig
    
    public init(config: DeflateConfig,
                channel: Channel,
                socketType: WebSocket.PeerType) {
        
        self.config = config
        self.channel = channel
        self.extendedSocketType = socketType
        
        self._enabled = NIOLockedValueBox(true)
        self._logging = NIOLockedValueBox(true)
        
        switch extendedSocketType {
        case .server:
           
            // need to determine values for other args
            let winSize = PMCE.sizeFor(bits: config.serverConfig.maxWindowBits ?? 15)
            
            let zscConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: config.serverConfig.zlibConfig.compressionLevel,
                                            memoryLevel: config.serverConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)
            
            let zsdConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: config.clientConfig.zlibConfig.compressionLevel,
                                            memoryLevel: config.clientConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)
            self.compressorBox = NIOLoopBoundBox(CompressionAlgorithm.deflate(configuration: zscConf).compressor,
                                                 eventLoop: channel.eventLoop)
            self.decompressorBox = NIOLoopBoundBox(CompressionAlgorithm.deflate(configuration: zsdConf).decompressor,
                                                   eventLoop: channel.eventLoop)
            
        case .client:
           
            let winSize = PMCE.sizeFor(bits: config.clientConfig.maxWindowBits ?? 15)
            let zccConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: config.clientConfig.zlibConfig.compressionLevel,
                                            memoryLevel: config.clientConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)
            
            let zcdConf = ZlibConfiguration(windowSize: winSize,
                                            compressionLevel: config.serverConfig.zlibConfig.compressionLevel,
                                            memoryLevel: config.serverConfig.zlibConfig.memLevel,
                                          strategy: .huffmanOnly)

            self.compressorBox = NIOLoopBoundBox(CompressionAlgorithm.deflate(configuration: zccConf).compressor,
                                                 eventLoop: channel.eventLoop)
            self.decompressorBox = NIOLoopBoundBox( CompressionAlgorithm.deflate(configuration: zcdConf).decompressor,
                                                    eventLoop: channel.eventLoop)
            
        }
        
        //?TODO wonder if I shold move this to enabled?
        do {
            try compressorBox.value?.startStream()
        }
        catch {
            logger.error("error starting stream : \(error)")
        }
        do {
            try decompressorBox.value?.startStream()
        }
        catch {
            logger.error("error starting stream : \(error)")
        }
    }
    
    // websocket send calls this to compress.
    public func compressed(_ buffer: ByteBuffer,
                            fin: Bool = true,
                            opCode: WebSocketOpcode = .binary) throws -> WebSocketFrame {
        
        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "channel not configured.")
        }
        let startSize = buffer.readableBytes
        
        if logging {
            logger.debug("compressing \(startSize) bytes for \(opCode)")
        }
        do {
            var mutBuffer = buffer
            let startTime = Date()
            
            let compressed =
            try mutBuffer.compressStream(with: compressorBox.value!,
                                         flush: .sync,
                                         allocator: channel.allocator)
            if logging {
                let endTime = Date()
                let endSize = compressed.readableBytes
                
                logger.debug("compressed \(startSize) to \(endSize) bytes @ \(startSize / endSize) ratio from")
                switch extendedSocketType {
                case .server:
                    logger.debug(" \(config.serverConfig.zlibConfig)")
                case .client:
                    logger.debug(" \(config.clientConfig.zlibConfig)")
                }
                
                logger.debug("in \(startTime.distance(to: endTime))")
            }
            
            if !config.shouldTakeOverContext(isServer: extendedSocketType == .server) {
                try compressorBox.value?.resetStream()
            }
            
            var frame = WebSocketFrame(
                fin: true,
                opcode: opCode,
                maskKey: self.makeMaskKey(),
                data: compressed
            )
            
            frame.rsv1 = true // denotes compression
            frame.data = compressed.getSlice(at: compressed.readerIndex,
                                             length: compressed.readableBytes - 4) ?? compressed

            return frame
        }
        catch {
            logger.error("send compression failed \(error)")
        }
        
        return WebSocketFrame(fin:fin, rsv1: false, opcode:opCode, data: buffer)
    }
    
    // websocket calls these from handleIncoming to decompress.
    public func decompressed(_ frame: WebSocketFrame) throws -> WebSocketFrame  {

        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "channel not configured.")
        }
        let startTime = Date()
        
        
        var data = frame.data
        let startSize = data.readableBytes
        if logging {
            logger.debug("decompressing  \(startSize) bytes for \(frame.opcode)")
        }
        let decompressed =
        try data.decompressStream(with: self.decompressorBox.value!,
                                  maxSize: .max,
                                  allocator: channel.allocator)
        if logging {
            let endTime = Date()
            
            let endSize = decompressed.readableBytes
            
            logger.debug("deompressed \(startSize) to \(endSize) bytes @ \(endSize/startSize) ratio from")
            switch extendedSocketType {
            case .server:
                logger.debug(" \(config.serverConfig.zlibConfig)")
            case .client:
                logger.debug(" \(config.clientConfig.zlibConfig)")
            }
            
            logger.debug("in \(startTime.distance(to: endTime))")
        }
        if !config.shouldTakeOverContext(isServer: extendedSocketType == .server) {
            if logging { logger.debug("websocket-kit: resetting stream") }
            try decompressorBox.value?.resetStream()
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
    
    // websocket calls from handleIncoming as a server to handle client masked compressed frames. This was epxerimentally determined.
    public func unmaskedDecompressedUnamsked(frame: WebSocketFrame) throws -> WebSocketFrame {
        if logging {
            logger.debug("unmaksing/decomp/unmasking frame \(frame.opcode) data...")
        }
        let unmaskedCompressedFrame = unmasked(frame: frame)

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
            return WebSocketMaskingKey.random()
        case .server:
            return nil
        }
    }
    
    // server decomp uses this as RFC-7692 says client must mask msgs but server must not.
    private func unmasked(frame maskedFrame: WebSocketFrame) -> WebSocketFrame {
        var unmaskedData = maskedFrame.data
        unmaskedData.webSocketUnmask(maskedFrame.maskKey!)
        return WebSocketFrame(fin: maskedFrame.fin,
                              rsv1: maskedFrame.rsv1,
                              rsv2: maskedFrame.rsv2,
                              rsv3: maskedFrame.rsv3,
                              opcode: maskedFrame.opcode,
                              maskKey: maskedFrame.maskKey,//should this be nil
                              data: unmaskedData,
                              extensionData: maskedFrame.extensionData)
    }

    deinit {
        do {
            try compressorBox.value?.finishStream()
            try decompressorBox.value?.finishStream()
        }
        catch {
            logger.error("PMCE: deinit: error finishing stream(s) : \(error)")
        }
    }
    
}

extension PMCE.DeflateConfig: Equatable {
    public static func == (lhs: PMCE.DeflateConfig,
                           rhs: PMCE.DeflateConfig) -> Bool {
        return lhs.headerParams() == rhs.headerParams()
    }
}

extension PMCE.DeflateConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "DeflateConfig {\nclient:\(clientConfig)\nserver:\(serverConfig)\n}"
    }
}

extension PMCE.DeflateConfig.ClientConfig: Equatable {
    public static func == (lhs: PMCE.DeflateConfig.ClientConfig,
                           rhs: PMCE.DeflateConfig.ClientConfig) -> Bool {
        
        return lhs.takeover == rhs.takeover &&
        lhs.maxWindowBits == rhs.maxWindowBits &&
        // I hate swift.
        (lhs.zlibConfig.compressionLevel == rhs.zlibConfig.compressionLevel ) &&
        (lhs.zlibConfig.memLevel == rhs.zlibConfig.memLevel )
      
    }
}

extension PMCE.DeflateConfig.ServerConfig: Equatable {
    
    public static func == (lhs: PMCE.DeflateConfig.ServerConfig,
                           rhs: PMCE.DeflateConfig.ServerConfig) -> Bool {
        return lhs.takeover == rhs.takeover &&
        lhs.maxWindowBits == rhs.maxWindowBits &&
        // I hate swift.
        (lhs.zlibConfig.compressionLevel == rhs.zlibConfig.compressionLevel ) &&
        (lhs.zlibConfig.memLevel == rhs.zlibConfig.memLevel )
    }
    
}

extension PMCE.DeflateConfig.ClientConfig: CustomDebugStringConvertible {
    
    public var debugDescription: String {
        "ClientConfig {\ntakeOver:\(takeover.rawValue.debugDescription)\nmaxWindowBits:\(maxWindowBits.debugDescription)\nzlib:\(zlibConfig.debugDescription)}"
    }
}

extension PMCE.DeflateConfig.ServerConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ServerConfig {\ntakeOver:\(takeover.rawValue.debugDescription)\nmaxWindowBits:\(maxWindowBits.debugDescription)\nzlib:\(zlibConfig.debugDescription)}"
    }
}
