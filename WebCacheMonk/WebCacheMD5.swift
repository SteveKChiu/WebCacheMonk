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

import Foundation

//---------------------------------------------------------------------------

private let shift: [UInt32] = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]
private let table: [UInt32] = (0 ..< 64).map { UInt32(0x100000000 * abs(sin(Double($0 + 1)))) }

public func WebCacheMD5(text: String) -> String {
    var message = [UInt8](text.utf8)
    let messageLenBits = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 {
        message.append(0)
    }
    
    let lengthBytes = [UInt8](count: 8, repeatedValue: 0)
    UnsafeMutablePointer<UInt64>(lengthBytes).memory = messageLenBits.littleEndian
    message += lengthBytes
    
    var a: UInt32 = 0x67452301
    var b: UInt32 = 0xEFCDAB89
    var c: UInt32 = 0x98BADCFE
    var d: UInt32 = 0x10325476
    
    for chunkOffset in 0.stride(to: message.count, by: 64) {
        let chunk = UnsafePointer<UInt32>(UnsafePointer<UInt8>(message) + chunkOffset)
        let originalA = a
        let originalB = b
        let originalC = c
        let originalD = d
        
        for j in 0 ..< 64 {
            var f: UInt32 = 0
            var bufferIndex = j
            let round = j >> 4
            
            switch round {
            case 0:
                f = (b & c) | (~b & d)
            case 1:
                f = (b & d) | (c & ~d)
                bufferIndex = (bufferIndex * 5 + 1) & 0x0F
            case 2:
                f = b ^ c ^ d
                bufferIndex = (bufferIndex * 3 + 5) & 0x0F
            case 3:
                f = c ^ (b | ~d)
                bufferIndex = (bufferIndex * 7) & 0x0F
            default:
                break
            }
            
            let sa = shift[(round << 2) | (j & 3)]
            let tmp = a &+ f &+ UInt32(littleEndian: chunk[bufferIndex]) &+ table[j]
            a = d
            d = c
            c = b
            b = b &+ (tmp << sa | tmp >> (32 - sa))
        }
        
        a = a &+ originalA
        b = b &+ originalB
        c = c &+ originalC
        d = d &+ originalD
    }
    
    return String(format: "%08X%08X%08X%08X", a.bigEndian, b.bigEndian, c.bigEndian, d.bigEndian)
}
