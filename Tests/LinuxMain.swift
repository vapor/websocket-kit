#if os(Linux)

import XCTest
@testable import WebSocketTests
XCTMain([
    testCase(WebSocketTests.allTests),
])

#endif
