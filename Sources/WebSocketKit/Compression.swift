import CZlib
import NIOCore
import Foundation

/// Namespace for compression code
public enum Compression {
    
    public struct Configuration {
        public var algorithm: Algorithm
        public var decompressionLimit: DecompressionLimit
        
        public init(algorithm: Algorithm, decompressionLimit: DecompressionLimit) {
            self.algorithm = algorithm
            self.decompressionLimit = decompressionLimit
        }
    }
    
    /// The compression algorithm
    public struct Algorithm {
        enum Base {
            case gzip
            case deflate
        }
        
        private let base: Base
        
        var window: CInt {
            switch base {
            case .deflate:
                return 15
            case .gzip:
                return 15 + 16
            }
        }
        
        private init(_ base: Base) {
            self.base = base
        }
        
        public static let gzip = Self(.gzip)
        public static let deflate = Self(.deflate)
    }
    
    /// Specifies how to limit decompression inflation.
    public struct DecompressionLimit: Sendable {
        private enum Limit {
            case none
            case size(Int)
            case ratio(Int)
        }
        
        private var limit: Limit
        
        /// No limit will be set.
        /// - warning: Setting `limit` to `.none` leaves you vulnerable to denial of service attacks.
        public static let none = DecompressionLimit(limit: .none)
        /// Limit will be set on the request body size.
        public static func size(_ value: Int) -> DecompressionLimit {
            return DecompressionLimit(limit: .size(value))
        }
        /// Limit will be set on a ratio between compressed body size and decompressed result.
        public static func ratio(_ value: Int) -> DecompressionLimit {
            return DecompressionLimit(limit: .ratio(value))
        }
        
        func exceeded(compressed: Int, decompressed: Int) -> Bool {
            switch self.limit {
            case .none:
                return false
            case .size(let allowed):
                return decompressed > allowed
            case .ratio(let ratio):
                return decompressed > compressed * ratio
            }
        }
    }
    
    public struct DecompressionError: Error, Hashable, CustomStringConvertible {
        
        private enum Base: Error, Hashable, Equatable {
            case limit
            case inflationError(Int)
            case initializationError(Int)
            case invalidTrailingData
        }
        
        private var base: Base
        
        private init(_ base: Base) {
            self.base = base
        }
        
        /// The set ``DecompressionLimit`` has been exceeded
        public static let limit = Self(.limit)
        
        /// An error occurred when inflating.  Error code is included to aid diagnosis.
        public static var inflationError: (Int) -> Self = {
            Self(.inflationError($0))
        }
        
        /// Decoder could not be initialised.  Error code is included to aid diagnosis.
        public static var initializationError: (Int) -> Self = {
            Self(.initializationError($0))
        }
        
        /// Decompression completed but there was invalid trailing data behind the compressed data.
        public static var invalidTrailingData = Self(.invalidTrailingData)
        
        public var description: String {
            return String(describing: self.base)
        }
    }
    
    struct Decompressor {
        private let limit: DecompressionLimit
        private var stream = z_stream()
        /// To better reserve capacity for the next inflations.
        private var maxLogarithmicRatio = 1.1
        
        init(limit: Compression.DecompressionLimit) {
            self.limit = limit
        }
        
        /// Assumes `buffer` is a new empty buffer.
        mutating func decompress(part: inout ByteBuffer, buffer: inout ByteBuffer) throws {
            let compressedLength = part.readableBytes
            var isComplete = false
            
            while part.readableBytes > 0 && !isComplete {
                try self.stream.inflatePart(
                    input: &part,
                    output: &buffer,
                    isComplete: &isComplete,
                    minimumCapacity: Int(pow(Double(compressedLength), maxLogarithmicRatio))
                )
                
                if self.limit.exceeded(
                    compressed: compressedLength,
                    decompressed: buffer.writerIndex + 1
                ) {
                    throw Compression.DecompressionError.limit
                }
                
            }
            
            let ratio = log(Double(buffer.readableBytes)) / log(Double(compressedLength))
            maxLogarithmicRatio = max(maxLogarithmicRatio, ratio)
            
            if part.readableBytes > 0 {
                throw DecompressionError.invalidTrailingData
            }
        }
        
        mutating func initializeDecoder(encoding: Compression.Algorithm) throws {
            self.stream.zalloc = nil
            self.stream.zfree = nil
            self.stream.opaque = nil
            
            let rc = CZlib_inflateInit2(&self.stream, encoding.window)
            guard rc == Z_OK else {
                throw Compression.DecompressionError.initializationError(Int(rc))
            }
        }
        
        mutating func deinitializeDecoder() {
            inflateEnd(&self.stream)
        }
    }
}

//MARK: - +z_stream
extension z_stream {
    mutating func inflatePart(
        input: inout ByteBuffer,
        output: inout ByteBuffer,
        isComplete: inout Bool,
        minimumCapacity: Int
    ) throws {
        try input.readWithUnsafeMutableReadableBytes { pointer in
            self.avail_in = UInt32(pointer.count)
            self.next_in = CZlib_voidPtr_to_BytefPtr(pointer.baseAddress!)
            
            defer {
                self.avail_in = 0
                self.next_in = nil
                self.avail_out = 0
                self.next_out = nil
            }
            
            isComplete = try self.inflatePart(to: &output, minimumCapacity: minimumCapacity)
            
            return pointer.count - Int(self.avail_in)
        }
    }
    
    private mutating func inflatePart(to buffer: inout ByteBuffer, minimumCapacity: Int) throws -> Bool {
        var rc = Z_OK
        
        buffer.reserveCapacity(5500)
        try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: minimumCapacity) { pointer in
            self.avail_out = UInt32(pointer.count)
            self.next_out = CZlib_voidPtr_to_BytefPtr(pointer.baseAddress!)
            
            rc = inflate(&self, Z_SYNC_FLUSH)
            guard rc == Z_OK || rc == Z_STREAM_END else {
                throw Compression.DecompressionError.inflationError(Int(rc))
            }
            
            return pointer.count - Int(self.avail_out)
        }
        
        return rc == Z_STREAM_END
    }
}
