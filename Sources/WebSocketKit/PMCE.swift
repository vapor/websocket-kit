import NIOHTTP1
import NIOWebSocket
import CompressNIO
import NIO
import Foundation

public protocol PMCEZlibConfiguration: Codable, Equatable, Sendable,CustomDebugStringConvertible  {
    var memLevel:Int32 {get set}
    var compressionLevel:Int32 {get set}
}

public final class PMCE:Sendable {
    
    /// Configures sending and receiving compressed data with DEFLATE.
    public struct DeflateConfig: Sendable {
        
        /// Identifies this extension per RFC-.
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
                                      cbits:UInt8?)
        
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
            
            /// Zlib options not found in RFC- for deflate.
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

        /// Will init an array of DeflateConfigs from parsed header values if possible.
        public static func configsFrom(headers:HTTPHeaders) -> [DeflateConfig] {
            print("getting configs from \(headers)")
            
            if let wsx = headers.first(name: wsxtHeader) {
                
                let offers = offers(in:wsx)
                
                let requestedOfferConfigs = offers.compactMap({offer in
                        config(from:offer)
                    }
                )
                
                return requestedOfferConfigs
            
            }
            else {
                print("Tried to init a PMCE config with headers that do not contain the Sec-Websocket-Extensions key")
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
            
            var arg = ConfArgs(.takeover, .takeover, nil,nil)
            
            for (idx,setting) in settings.enumerated() {
                let setting = setting
                print("#\(idx) \(setting)")
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
                
                print("first = \(first)")
                print("sane = \(sane)")
                
                if first == DeflateHeaderParams.cmwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.cbits = UInt8(trimmed) ?? nil
                    }
                    else
                    {
                        print("no arg for cmwb")
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
                        print("no arg for smwb")
                    }
                }
                else if sane == DeflateHeaderParams.cnct {
                    foo.cto = .noTakeover
                }
                else if sane == DeflateHeaderParams.snct {
                    foo.sto = .noTakeover
                }
                else if sane == ZlibHeaderParams.server_cmp_level {
                    print("checking for server cmp")
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        print(trimmed)
                    }
                    else
                    {
                        print("no arg for server_cmp_level")
                    }
                }
                else if sane == ZlibHeaderParams.server_mem_level {
                    if let arg = splits.last {
                        print("checking for server mem")
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        print(trimmed)
                    }
                    else
                    {
                        print("no arg for server_mem_level")
                    }
                }else if sane == ZlibHeaderParams.client_cmp_level {
                    print("checking for client cmp")
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        print(trimmed)
                    }
                    else
                    {
                        print("no arg for server_cmp_level")
                    }
                }else if sane == ZlibHeaderParams.client_mem_level {
                    print("checking for client mem")
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        print(trimmed)
                    }
                    else
                    {
                        print("no arg for client_mem_level")
                    }
                }
                else if first == "permessage-deflate" {
                    print("woops")
                }
                else {
                    print("unrecognized first split from setting \(setting)")
                }
            }
            else {
                print("couldnt parse arg; no first split @ =")
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
        /// TODO maybe im missing something.
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
                    serverCfg: ServerConfig) {
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
            
            /// TODO add headers for zlib config
            
            built += PMCE.DeflateConfig.ZlibHeaderParams.server_mem_level + " = " +
            "\(serverConfig.zlibConfig.memLevel)" + ";"
            
            built += PMCE.DeflateConfig.ZlibHeaderParams.server_cmp_level + " = " +
            "\(serverConfig.zlibConfig.compressionLevel)" + ";"
            
            built += PMCE.DeflateConfig.ZlibHeaderParams.client_mem_level + " = " +
            "\(clientConfig.zlibConfig.memLevel)" + ";"
            
            built += PMCE.DeflateConfig.ZlibHeaderParams.client_cmp_level + " = " +
            "\(clientConfig.zlibConfig.memLevel)" + ";"
            
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
    
    ///TODO DOcument these settings and perhaps come up with a header based way to configure them
    ///for a fully header based api maybe. but that would requrie actual acknowldgement and not getting dicked around.
    public struct ZlibConf: PMCEZlibConfiguration, CustomDebugStringConvertible {
        
        public var debugDescription: String {
            "ZlibConf {\nmemLevel:\(memLevel)\ncompressionLvel:\(compressionLevel)"
        }
        
        
        public static let maxRamMaxComp:ZlibConf = .init(memLevel: 9, compLevel: 9)
        public static let maxRamMinComp:ZlibConf = .init(memLevel: 9, compLevel: 1)
        
        public static let minRamMaxComp:ZlibConf = .init(memLevel: 1, compLevel: 9)
        public static let minRamMinComp:ZlibConf = .init(memLevel: 1, compLevel: 1)
        public static let midRamMidComp:ZlibConf = .init(memLevel: 5, compLevel: 5)
        
        public var memLevel:Int32
        public var compressionLevel:Int32
        
        public init(memLevel:Int32, compLevel:Int32) {
            assert( (-1...9).contains(compLevel) , "compLevel must be -1...9 ")
            assert( (1...9).contains(memLevel) , "memLevel must be 1...9 ")
            self.memLevel = memLevel
            self.compressionLevel = compLevel
        }
    }
    
    /// PMCE settings are under this header
    public static var wsxtHeader:String {"Sec-WebSocket-Extensions"}

    /// If you have to ask ...
    private let compressorBox:NIOLoopBoundBox<NIOCompressor?>
    
    /// If you have to ask ...
    private let decompressorBox:NIOLoopBoundBox<NIODecompressor?>
    
    // Tells pmce how to apply the deflate config as well as how to extract per RFC-.
    public let extendedSocketType:WebSocket.PeerType
    
    // the channel whose allocator to use for compression bytebuffers as well as box event loops.
    public let channel:NIO.Channel?
    
    /// Converts windowBits to size of window.
    private static func sizeFor(bits:UInt8) -> Int32 {
        2^Int32(bits)
    }
  
    /// Represents the alg of pmce used with the PMCE struct.
    /// Currentonly only permessage-deflate is supported.
    let config: DeflateConfig
    
    public init(config: DeflateConfig,
                channel: Channel,
                socketType: WebSocket.PeerType) {
        self.config = config
        self.channel = channel
        self.extendedSocketType = socketType
        
        switch extendedSocketType {
        case .server:
            print("websocket-kit: WebSocket.init() configuring as Zlib as server")
            
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
            print("websocket-kit: WebSocket.init() configuring as client")
            print("websocket-kit: WebSocket.init() \(config)")

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
        
        do {
            try compressorBox.value?.startStream()
        }
        catch {
            print("WebSocket.init() error starting stream : \(error)")
        }
        do {
            try decompressorBox.value?.startStream()
        }
        catch {
            print("WebSocket.init() error starting stream : \(error)")
        }
    }
    
    // websocket send calls this
    public func compressed(_ buffer: ByteBuffer,
                            fin: Bool = true,
                            opCode: WebSocketOpcode = .binary) throws -> WebSocketFrame {
        
        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "channel not configured.")
        }
        let startSize = buffer.readableBytes
        print("compressing \(startSize) bytes for \(opCode)")
        do {
            var mutBuffer = buffer
            let startTime = Date()
            
            let compressed =
            try mutBuffer.compressStream(with: compressorBox.value!,
                                         flush: .sync,
                                         allocator: channel.allocator)
            let endTime = Date()
            let endSize = compressed.readableBytes
            print("compressed \(startSize) to \(endSize) bytes @ \(startSize / endSize) ratio from")
            switch extendedSocketType {
            case .server:
                print(" \(config.serverConfig.zlibConfig)")
            case .client:
                print(" \(config.clientConfig.zlibConfig)")
            }
            
            print("in \(startTime.distance(to: endTime))")
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
            print("websocket-kit: send compression failed \(error)")
        }
        return WebSocketFrame(fin:fin, rsv1: false, opcode:opCode, data: buffer)
    }
    
    // websocket calls these from handleIncoming
    public func decompressed(_ frame: WebSocketFrame) throws -> WebSocketFrame  {

        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "channel not configured.")
        }
        let startTime = Date()
        
        
        var data = frame.data
        let startSize = data.readableBytes
        print("decompressing  \(startSize) bytes for \(frame.opcode)")
        let decompressed =
        try data.decompressStream(with: self.decompressorBox.value!,
                                  maxSize: .max,
                                  allocator: channel.allocator)
        let endTime = Date()
        
        let endSize = decompressed.readableBytes
        
        print("deompressed \(startSize) to \(endSize) bytes @ \(endSize/startSize) ratio from")
        switch extendedSocketType {
        case .server:
            print(" \(config.serverConfig.zlibConfig)")
        case .client:
            print(" \(config.clientConfig.zlibConfig)")
        }
        
        print("in \(startTime.distance(to: endTime))")
        if !config.shouldTakeOverContext(isServer: extendedSocketType == .server) {
            print("websocket-kit: resetting stream")
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
    
    // websocket calls frorm handleIncoming
    public func unmaskedDecompressedUnamsked(frame: WebSocketFrame) throws -> WebSocketFrame {
        print("websocket-kit: unmaksing/decomp/unmasking frame \(frame.opcode) data...")
        
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
    
    // server decomp uses this as RFC- says client must mask msgs but server must not.
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
            print("PMCE: deinit: error finishing stream(s) : \(error)")
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
