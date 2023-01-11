import CZlib

public enum Decompression {
    
    public struct Configuration {
        /// `deflate` is the main compression algorithm for web-sockets (RFC 7692),
        /// and for now we only support `deflate`.
        let algorithm: Compression.Algorithm = .deflate
        
        private init() { }
        
        public static let enabled = Configuration()
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
        private var stream = z_stream()
        
        /// Assumes `buffer` is a new empty buffer.
        mutating func decompress(part: inout ByteBuffer, buffer: inout ByteBuffer) throws {
            var isComplete = false
            
            while part.readableBytes > 0 && !isComplete {
                try self.stream.inflatePart(
                    input: &part,
                    output: &buffer,
                    isComplete: &isComplete
                )
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
