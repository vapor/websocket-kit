//
//  PMCETests.swift
//
//
//  Created by Jimmy Hough Jr on 5/17/23.
//

import XCTest
@testable import WebSocketKit

class PMCEConfigTests:XCTestCase {
    typealias Config = PMCE.PMCEConfig
   
    func test_configsFromHeaders_returns_no_configs_if_empty() {
        let testSubject = PMCE.PMCEConfig.self
        let result = testSubject.configsFrom(headers: [:])
        XCTAssertTrue(result.isEmpty, "Empty headers can contain no config.")
    }
    
//    func test_configsFromHeaders_returns_one_config_from_config_headers() {
//        let testSubject = PMCE.PMCEConfig.self
//        let config = PMCE.PMCEConfig(clientCfg: .init(takeover: .noTakeover),
//                                        serverCfg: .init(takeover: .noTakeover))
//        let result = testSubject.configsFrom(headers: config.headers())
//        XCTAssertTrue(result.count == 1, "A single deflate config should produce headers for a single defalte config.")
//    }
//    
//    func test_configsFromHeaders_returns_the_same_config_from_config_headers() {
//        let testSubject = PMCE.PMCEConfig.self
//        let config = PMCE.PMCEConfig(clientCfg: .init(takeover: .noTakeover),
//                                        serverCfg: .init(takeover: .noTakeover))
//        let result = testSubject.configsFrom(headers: config.headers())
//        XCTAssertTrue(result.first == config, "A config converted to headers should be equal to a config converted from headers. ")
//    }
    
}

class PMCETests:XCTestCase {
    
    //compress-nio checks these would fail if api changes.
    func testCompressDcompressNodeServerResponse_deflate() {
        let string1 = "Welcome, you are connected!"
        var sBuf = ByteBuffer(string: string1)
        var compressedBuffer = try? sBuf.compress(with: .deflate())
        print("\(String(buffer:compressedBuffer ?? ByteBuffer()))")
        let decompressedBuffer = try? compressedBuffer?.decompress(with: .deflate())
        let string2 = String(buffer: decompressedBuffer ?? ByteBuffer(string: ""))

        XCTAssertNotNil(compressedBuffer, "buffer failed to compress with deflate")
        XCTAssertNotNil(decompressedBuffer, "compressed buffer fialed to inflate")
        XCTAssertEqual(string1, string2, "Comp/decomp was not symmetrical!")

    }

    func testCompressDcompressNodeServerResponse_gzip() {
        let string1 = "Welcome, you are connected!"
        var sBuf = ByteBuffer(string: string1)
        var compressedBuffer = try? sBuf.compress(with: .gzip())
        print("\(String(buffer:compressedBuffer ?? ByteBuffer()))")
        let decompressedBuffer = try? compressedBuffer?.decompress(with: .gzip())
        let string2 = String(buffer: decompressedBuffer ?? ByteBuffer(string: ""))

        XCTAssertNotNil(compressedBuffer, "buffer failed to compress with gzip")
        XCTAssertNotNil(decompressedBuffer, "compressed buffer fialed to gIp")
        XCTAssertEqual(string1, string2, "Comp/decomp was not symmetrical!")

    }
   
}
