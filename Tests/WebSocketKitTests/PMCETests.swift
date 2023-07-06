//
//  File.swift
//
//
//  Created by Jimmy Hough Jr on 5/17/23.
//

import XCTest
@testable import WebSocketKit

///TODO Fill in some tests ?
class PMCEConfigTests:XCTestCase {
    typealias Config = PMCE.DeflateConfig
   
    
}

///TODO Fill in some tests ?
class PMCETests:XCTestCase {
    
    //compressoion checks
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
