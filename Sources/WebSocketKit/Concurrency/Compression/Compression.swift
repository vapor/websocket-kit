
public enum Compression {
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
        
        public static let gzip = Self(base: .gzip)
        public static let deflate = Self(base: .deflate)
    }
}
