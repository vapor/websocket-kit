import CZlib

public enum Decompression {
    
    public struct Configuration {
        public var algorithm: Compression.Algorithm
        public var limit: Limit
        
        public init(algorithm: Compression.Algorithm, limit: Limit) {
            self.algorithm = algorithm
            self.limit = limit
        }
    }
    
    /// Specifies how to limit decompression inflation.
    public struct Limit: Sendable {
        private enum Base {
            case none
            case size(Int)
            case ratio(Int)
        }
        
        private var limit: Base
        
        /// No limit will be set.
        /// - warning: Setting `limit` to `.none` leaves you vulnerable to denial of service attacks.
        public static let none = Limit(limit: .none)
        /// Limit will be set on the request body size.
        public static func size(_ value: Int) -> Limit {
            return Limit(limit: .size(value))
        }
        /// Limit will be set on a ratio between compressed body size and decompressed result.
        public static func ratio(_ value: Int) -> Limit {
            return Limit(limit: .ratio(value))
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
    
    public struct DecompressionError: Error, Equatable, CustomStringConvertible {
        
        private enum Base: Error, Equatable {
            case limit
            case inflationError(Int)
            case initializationError(Int)
            case invalidTrailingData
        }
        
        private var base: Base
        
        /// The set ``DecompressionLimit`` has been exceeded
        public static let limit = Self(base: .limit)
        
        /// An error occurred when inflating.  Error code is included to aid diagnosis.
        public static var inflationError: (Int) -> Self = {
            Self(base: .inflationError($0))
        }
        
        /// Decoder could not be initialised.  Error code is included to aid diagnosis.
        public static var initializationError: (Int) -> Self = {
            Self(base: .initializationError($0))
        }
        
        /// Decompression completed but there was invalid trailing data behind the compressed data.
        public static var invalidTrailingData = Self(base: .invalidTrailingData)
        
        public var description: String {
            return String(describing: self.base)
        }
    }
    
    struct Decompressor {
        private let limit: Limit
        private var stream = z_stream()
        
        init(limit: Limit) {
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
                    isComplete: &isComplete
                )
                
                if self.limit.exceeded(
                    compressed: compressedLength,
                    decompressed: buffer.writerIndex + 1
                ) {
                    throw DecompressionError.limit
                }
            }
            
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
                throw DecompressionError.initializationError(Int(rc))
            }
        }
        
        mutating func deinitializeDecoder() {
            inflateEnd(&self.stream)
        }
    }
}

//MARK: - +z_stream
private extension z_stream {
    mutating func inflatePart(
        input: inout ByteBuffer,
        output: inout ByteBuffer,
        isComplete: inout Bool
    ) throws {
        let minimumCapacity = input.readableBytes * 4
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
        
        try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: minimumCapacity) { pointer in
            self.avail_out = UInt32(pointer.count)
            self.next_out = CZlib_voidPtr_to_BytefPtr(pointer.baseAddress!)
            
            rc = inflate(&self, Z_SYNC_FLUSH)
            guard rc == Z_OK || rc == Z_STREAM_END else {
                throw Decompression.DecompressionError.inflationError(Int(rc))
            }
            
            return pointer.count - Int(self.avail_out)
        }
        
        return rc == Z_STREAM_END
    }
}
