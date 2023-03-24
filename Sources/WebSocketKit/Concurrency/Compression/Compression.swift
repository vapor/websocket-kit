
enum Compression {
    enum Algorithm {
        case deflate
        
        var window: CInt {
            switch self {
            case .deflate:
                return 15
            }
        }
    }
}
