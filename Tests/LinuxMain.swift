import XCTest

import WebSocketTests

var tests = [XCTestCaseEntry]()
tests += WebSocketTests.allTests()
XCTMain(tests)