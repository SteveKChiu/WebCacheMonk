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

public protocol WebCacheReceiver : class {
    func onReceiveResponse(response: NSURLResponse, offset: Int64, length: Int64?, totalLength: Int64?, progress: NSProgress?)
    func onReceiveData(data: NSData, progress: NSProgress?)
    func onReceiveEnd(progress progress: NSProgress?)
    func onReceiveError(error: NSError?, progress: NSProgress?)
}

//---------------------------------------------------------------------------

public class WebCacheFilter : WebCacheReceiver {
    private let receiver: WebCacheReceiver
    private var filter: WebCacheReceiver?
    private var onMissingHandler: ((NSProgress?) -> Void)?
    
    public init(_ receiver: WebCacheReceiver, onMissing: (NSProgress?) -> Void) {
        self.receiver = receiver
        self.onMissingHandler = onMissing
    }
    
    public init(_ receiver: WebCacheReceiver, filter: WebCacheReceiver) {
        self.receiver = receiver
        self.filter = filter
    }
    
    public func onReceiveResponse(response: NSURLResponse, offset: Int64, length: Int64?, totalLength: Int64?, progress: NSProgress?) {
        self.filter?.onReceiveResponse(response, offset: offset, length: length, totalLength: totalLength, progress: progress)
        self.receiver.onReceiveResponse(response, offset: offset, length: length, totalLength: totalLength, progress: progress)
    }
    
    public func onReceiveData(data: NSData, progress: NSProgress?) {
        self.filter?.onReceiveData(data, progress: progress)
        self.receiver.onReceiveData(data, progress: progress)
    }
    
    public func onReceiveEnd(progress progress: NSProgress?) {
        self.filter?.onReceiveEnd(progress: progress)
        self.receiver.onReceiveEnd(progress: progress)
    }
    
    public func onReceiveError(error: NSError?, progress: NSProgress?) {
        if let onMissingHandler = self.onMissingHandler where error == nil {
            onMissingHandler(progress)
        } else {
            self.filter?.onReceiveError(error, progress: progress)
            self.receiver.onReceiveError(error, progress: progress)
        }
    }
}

//---------------------------------------------------------------------------

public class WebCacheDataReceiver : WebCacheReceiver {
    private var completion: ((WebCacheDataReceiver, NSProgress?) -> Void)?
    private var acceptPartial: Bool
    private var sizeLimit: Int64
    
    public var url: String
    public var response: NSURLResponse?
    public var offset: Int64?
    public var length: Int64?
    public var totalLength: Int64?
    public var buffer: NSMutableData?
    public var error: NSError?
    
    public init(url: String, acceptPartial: Bool = true, sizeLimit: Int = 0, completion: (WebCacheDataReceiver, NSProgress?) -> Void) {
        self.url = url
        self.completion = completion
        self.acceptPartial = acceptPartial
        self.sizeLimit = Int64(sizeLimit <= 0 ? Int.max : sizeLimit)
    }
        
    public func onReceiveResponse(response: NSURLResponse, offset: Int64, length: Int64?, totalLength: Int64?, progress: NSProgress?) {
        self.response = response
        self.offset = offset
        self.length = length
        self.totalLength = totalLength
        
        var isValid = true
        if let length = length, totalLength = totalLength {
            isValid = length <= self.sizeLimit && (self.acceptPartial || length == totalLength)
        } else if !self.acceptPartial {
            isValid = false
        }
        
        if isValid {
            self.buffer = NSMutableData()
        } else {
            self.buffer = nil
            self.completion?(self, progress)
            self.completion = nil
        }
    }
    
    public func onReceiveData(data: NSData, progress: NSProgress?) {
        if let buffer = self.buffer {
            if Int64(buffer.length) + Int64(data.length) > self.sizeLimit {
                self.buffer = nil
                self.completion?(self, progress)
                self.completion = nil
            } else {
                buffer.appendData(data)
            }
        }
    }
    
    public func onReceiveEnd(progress progress: NSProgress?) {
        self.completion?(self, progress)
        self.completion = nil
        self.buffer = nil
    }
    
    public func onReceiveError(error: NSError?, progress: NSProgress?) {
        self.error = error
        self.completion?(self, progress)
        self.completion = nil
        self.buffer = nil
    }
}
