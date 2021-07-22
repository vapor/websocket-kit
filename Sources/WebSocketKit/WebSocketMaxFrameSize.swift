public struct WebSocketMaxFrameSize: ExpressibleByIntegerLiteral {
    public let value: Int
    
    public init(_ value: Int) {
        precondition(value <= UInt32.max, "invalid overlarge max frame size")
        self.value = value
    }

    public init(integerLiteral value: Int) {
        precondition(value <= UInt32.max, "invalid overlarge max frame size")
        self.value = value
    }

    public static var `default`: Self {
        self.init(integerLiteral: 1 << 14)
    }
}
