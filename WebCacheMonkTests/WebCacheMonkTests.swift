//
// https://github.com/SteveKChiu/WebCacheMonk
//
// Copyright 2015, Steve K. Chiu <steve.k.chiu@gmail.com>
//
// The MIT License (http://www.opensource.org/licenses/mit-license.php)
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//

import XCTest
@testable import WebCacheMonk

//---------------------------------------------------------------------------

class WebCacheMonkTests: XCTestCase {
    
    func testFetch() {
        let cache = WebCache()
        let expect = expectation(description: "fetch")
    
        cache.fetch("http://cdn.akamai.steamstatic.com/steam/apps/352460/capsule_616x353.jpg") {
            info, data in
            
            XCTAssert(data != nil)
            
            cache.fetch("http://cdn.akamai.steamstatic.com/steam/apps/352460/capsule_616x353.jpg") {
                info2, data2 in
                
                XCTAssert(data2 != nil)
                expect.fulfill()
            }
        }
        
        waitForExpectations(timeout: 999) {
            error in
            
            XCTAssertNil(error, "Error")
        }
    }
    
}
