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
        
        public static var logger = Logger(label: "PMCEConfig")
        
        public struct DeflateConfig: Sendable {
            
            public struct AgreedParameters:Hashable, Sendable {
                /// Whether the server reuses the compression window acorss messages (takes over context) or not.
                public let takeover: ContextTakeoverMode
                
                /// The max size of the window in bits.
                public let maxWindowBits: UInt8
                
                public init(
                    takeover: ContextTakeoverMode = .takeover,
                    maxWindowBits: UInt8 = 15
                ) {
                    self.takeover = takeover
                    self.maxWindowBits = maxWindowBits
                }
                
            }
            
            /// Configures zlib with more granularity.
            public struct ZlibConf: Hashable, CustomDebugStringConvertible, Sendable {
                
                public var debugDescription: String {
                    "ZlibConf{memLevel:\(memLevel), compLevel: \(compressionLevel)}"
                }
                
                /// Convenience members for common combinations of resource allocation.
                public static let maxRamMaxComp: ZlibConf = .init(memLevel: 9, compLevel: 9)
                public static let maxRamMidComp: ZlibConf = .init(memLevel: 9, compLevel: 5)
                public static let maxRamMinComp: ZlibConf = .init(memLevel: 9, compLevel: 1)
                
                public static let midRamMinComp: ZlibConf = .init(memLevel: 5, compLevel: 1)
                public static let midRamMidComp: ZlibConf = .init(memLevel: 5, compLevel: 5)
                public static let midRamMaxComp: ZlibConf = .init(memLevel: 5, compLevel: 9)
                
                public static let minRamMinComp: ZlibConf = .init(memLevel: 1, compLevel: 5)
                public static let minRamMidComp: ZlibConf = .init(memLevel: 1, compLevel: 1)
                public static let minRamMaxComp: ZlibConf = .init(memLevel: 1, compLevel: 9)

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
                
                public var memLevel: Int32
                
                public var compressionLevel: Int32
                
                public init(memLevel: Int32, compLevel: Int32) {
                    assert( (-1...9).contains(compLevel),
                            "compLevel must be -1(default)...9 ")
                    assert( (1...9).contains(memLevel),
                            "memLevel must be 1...9 ")
                    self.memLevel = memLevel
                    self.compressionLevel = compLevel
                }
            }
            
            /// These are negotiated.
            public let agreedParams: AgreedParameters
            
            /// Zlib options not found in RFC-7692 for deflate can be passed in by the initialing side..
            public let zlibConfig: ZlibConf

            public init(agreedParams: AgreedParameters,
                        zlib: ZlibConf = .defaultConfig()) {
                
                assert((9...15).contains(agreedParams.maxWindowBits),
                       "Window size must be between the values 9 and 15")
               
                self.agreedParams = agreedParams
                self.zlibConfig = zlib
            }
        }
        
        /// Identifies this extension per RFC-7692.
        public static let pmceName = "permessage-deflate"
        
        /// Represents the states for using the same compression window across messages or not.
        public enum ContextTakeoverMode: String, Codable, CaseIterable, Sendable {
            case takeover
            case noTakeover
        }
        
        /// Holds the  config.
        public let deflateConfig: DeflateConfig
        
        /// A PMCE Config for client and server.
        public typealias ClientServerPMCEConfig = (client: PMCEConfig?,
                                                   server: PMCEConfig?)

        /// Will init an array of ClientServerConfigs from parsed header values if possible.
        public static func configsFrom(headers:HTTPHeaders) -> [ClientServerPMCEConfig] {
            
            if let wsx = headers.first(name: wsxtHeader)
            {
                return offers(in: wsx).compactMap({config(from: $0)})
            }
            else {
                return []
            }
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
            
             let mwb = deflateConfig.agreedParams.maxWindowBits
             components += [
                "\(DeflateHeaderParams.cmwb)=\(q)\(mwb)\(q)",
                "\(DeflateHeaderParams.smwb)=\(q)\(mwb)\(q)",
             ]
            
            return components.joined(separator: ";")
        }
        
        private typealias ConfArgs = (sto: ContextTakeoverMode,
                                      cto: ContextTakeoverMode,
                                      sbits: UInt8?,
                                      cbits: UInt8?)
        
        private static func offers(in headerValue: String) -> [Substring] {
            return headerValue.split(separator: ",")
        }
        
        private static func config(from offer: Substring) -> ClientServerPMCEConfig {

            // settings in an offer are split with ;
            // You will need to add a dependency on https://github.com/apple/swift-algorithms.git for this.
            let settings = offer
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0 != PMCE.PMCEConfig.pmceName }
            
            var arg = ConfArgs(.takeover, .takeover, nil, nil)
            
            for setting in settings {
                arg = self.arg(from: setting,
                               into: &arg)
            }
            
            let agreedClient = DeflateConfig.AgreedParameters(takeover:  arg.cto,
                                                maxWindowBits: arg.cbits ?? 15)
                
            let agreedServer = DeflateConfig.AgreedParameters(takeover: arg.sto,
                                                maxWindowBits: arg.sbits ?? 15)
            
          
            
            return (client:PMCEConfig(config: DeflateConfig(agreedParams: agreedClient,
                                                     zlib: .defaultConfig())),
                    server:PMCEConfig(config: DeflateConfig(agreedParams: agreedServer,
                                                     zlib: .defaultConfig())) )
        }
        
        private static func arg(from setting:String,
                                into foo:inout ConfArgs) -> ConfArgs {
            
            let splits = setting.split(separator:"=")
            
            if let first = splits.first {
                
                let trimmedName = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedName == DeflateHeaderParams.cmwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                        foo.cbits = UInt8(trimmed)
                    }
                }
                else if first == DeflateHeaderParams.smwb {
                    
                    if let arg = splits.last {
                        let trimmed = arg.replacingOccurrences(of: "\"",
                                                               with: "")
                        foo.sbits = UInt8(trimmed) ?? nil
                    }
                   
                }
                else if trimmedName == DeflateHeaderParams.cnct {
                    foo.cto = .noTakeover
                }
                else if trimmedName == DeflateHeaderParams.snct {
                    foo.sto = .noTakeover
                }
                else if first == PMCE.PMCEConfig.pmceName {
                        PMCEConfig.logger.error("oops something didnt parse in \(setting).")
                }
                else {
                        PMCEConfig.logger.trace("unrecognized first split from setting \(setting). Maybe the header is malformed ?")
                }
            }
            else {
                
                PMCEConfig.logger.error("couldnt parse arg; no first split @ =. Maybe header is malformed.")
            }
            return foo
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
    public let extendedSocketType: WebSocket.PeerType
    
    /// The channel whose allocator to use for the compression ByteBuffers and  box event loops.
    public let channel: NIO.Channel?
   
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
        
        switch extendedSocketType {
        case .server:
            
            let winSize = Int32(serverConfig.deflateConfig.agreedParams.maxWindowBits)
            logger.trace("extending server with window size \(winSize)")
            
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
           
            
        case .client:

            let winSize = Int32(clientConfig.deflateConfig.agreedParams.maxWindowBits)
            
            logger.trace("extending client with window size \(winSize)")

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
            
           
        }
        startStreams()
    }
    
   
    func startStreams() {
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
    
    private func stopStreams() {
        do {
            try compressorBox.value?.finishStream()
        }
        catch {
            logger.error("PMCE:error finishing stream(s) : \(error)")
        }
        
        do {
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

        do {
            var mutBuffer = buffer

            if !notakeover {
                mutBuffer = unpad(buffer:buffer)
            }
            
            let compressed = try mutBuffer.compressStream(with: compressorBox.value!,
                                                          flush: .sync,
                                                          allocator: channel.allocator)

            if notakeover {
                try compressorBox.value?.resetStream()
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
    }

    /// Websocket calls  from handleIncoming to decompress.
    public func decompressed(_ frame: WebSocketFrame) throws -> WebSocketFrame  {

        guard let channel = channel else {
            throw IOError(errnoCode: 0, reason: "PMCE: channel not configured.")
        }
        
        let takeover = shouldTakeOverContext()

        var data = frame.data
        
        if takeover {
            data = pad(buffer:data)
        }

        let decompressed =
        try data.decompressStream(with: self.decompressorBox.value!,
                                  maxSize: .max,
                                  allocator: channel.allocator)
        
        if !takeover {
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

    // Server decomp uses this as RFC-7692 says client must mask msgs but server must not.
    func unmasked(frame maskedFrame: WebSocketFrame) -> WebSocketFrame {

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

    public let logger = Logger(label: "PMCE")
    
    // for takeover
    private func pad(buffer:ByteBuffer) -> ByteBuffer {
        var mutbuffer = buffer
        mutbuffer.writeBytes(paddingOctets)
        return mutbuffer
    }

    private func unpad(buffer:ByteBuffer) -> ByteBuffer {
        return buffer.getSlice(at: 0, length: buffer.readableBytes - 4) ?? buffer
    }
    
    private func makeMaskKey() -> WebSocketMaskingKey? {
        switch extendedSocketType {
        
        case .client:
            let mask = WebSocketMaskingKey.random()
            return mask
        case .server:
            return nil
        }
    }
    
    private let compressorBox:NIOLoopBoundBox<NIOCompressor?>
    private let decompressorBox:NIOLoopBoundBox<NIODecompressor?>

    // 4 bytes used for compress and decompress when context takeover is being used.
    private let paddingOctets:[UInt8] = [0x00, 0x00, 0xff, 0xff]

    deinit {
       stopStreams()
    }
    
}

extension PMCE: CustomStringConvertible {
    public var description: String {
        """
        extendedSocketType: \(self.extendedSocketType),
        serverConfig: \(serverConfig),
        clientConfig: \(clientConfig)
        """
    }
}

extension PMCE.PMCEConfig: Equatable {
    public static func == (lhs: PMCE.PMCEConfig,
                           rhs: PMCE.PMCEConfig) -> Bool {
        return lhs.headerParams() == rhs.headerParams()
    }
}

extension PMCE.PMCEConfig: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(deflateConfig.hashValue )
        hasher.combine(self.headerParams())
    }
}

extension PMCE.PMCEConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "PMCEConfig {config: \(deflateConfig)}"
    }
}

extension PMCE.PMCEConfig: CustomStringConvertible {
    public var description: String {
       debugDescription
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

extension PMCE.PMCEConfig.DeflateConfig: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.agreedParams)
        hasher.combine(self.zlibConfig)
    }
}

extension PMCE.PMCEConfig.DeflateConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        DeflateConfig {agreedParams: \(agreedParams), zlib: \(zlibConfig)}
        """
    }
}

extension PMCE.PMCEConfig.DeflateConfig: CustomStringConvertible {
    public var description: String {
       debugDescription
    }
}
