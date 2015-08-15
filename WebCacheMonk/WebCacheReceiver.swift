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

public class WebCacheInfo {
    public var mimeType: String
    public var textEncoding: String?
    public var totalLength: Int64?
    public var headers = [String: String]()
    
    public init(mimeType: String?) {
        self.mimeType = mimeType ?? "application/octet-stream"
    }
    
    public init(from: WebCacheInfo) {
        self.mimeType = from.mimeType
        self.textEncoding = from.textEncoding
        self.totalLength = from.totalLength
        self.headers = from.headers
    }
    
    public static var HeaderKeys: Set<String> = [ "ETag" ]
}

public func == (lhs: WebCacheInfo, rhs: WebCacheInfo) -> Bool {
    return lhs.mimeType == rhs.mimeType
        && lhs.textEncoding == rhs.textEncoding
        && lhs.totalLength == rhs.totalLength
        && lhs.headers == rhs.headers
}

public func != (lhs: WebCacheInfo, rhs: WebCacheInfo) -> Bool {
    return !(lhs == rhs)
}

//---------------------------------------------------------------------------

public protocol WebCacheReceiver : class {
    func onReceiveInited(response response: NSURLResponse?, progress: NSProgress?)
    
    func onReceiveStarted(info: WebCacheInfo, offset: Int64, length: Int64?)
    func onReceiveData(data: NSData)
    func onReceiveFinished()
    
    func onReceiveAborted(error: NSError?)
}

//---------------------------------------------------------------------------

public class WebCacheFilter : WebCacheReceiver {
    private let receiver: WebCacheReceiver
    private var filter: WebCacheReceiver?
    private var progress: NSProgress?
    private var onMissingHandler: ((NSProgress?) -> Void)?
    
    public init(_ receiver: WebCacheReceiver, onMissing: (NSProgress?) -> Void) {
        self.receiver = receiver
        self.onMissingHandler = onMissing
    }
    
    public init(_ receiver: WebCacheReceiver, filter: WebCacheReceiver) {
        self.receiver = receiver
        self.filter = filter
    }
    
    public func onReceiveInited(response response: NSURLResponse?, progress: NSProgress?) {
        self.progress = progress
        self.filter?.onReceiveInited(response: response, progress: progress)
        self.receiver.onReceiveInited(response: response, progress: progress)
    }

    public func onReceiveStarted(info: WebCacheInfo, offset: Int64, length: Int64?) {
        self.filter?.onReceiveStarted(info, offset: offset, length: length)
        self.receiver.onReceiveStarted(info, offset: offset, length: length)
    }
    
    public func onReceiveData(data: NSData) {
        self.filter?.onReceiveData(data)
        self.receiver.onReceiveData(data)
    }
    
    public func onReceiveFinished() {
        self.filter?.onReceiveFinished()
        self.receiver.onReceiveFinished()
    }
    
    public func onReceiveAborted(error: NSError?) {
        if let onMissingHandler = self.onMissingHandler where error == nil {
            onMissingHandler(self.progress)
        } else {
            self.filter?.onReceiveAborted(error)
            self.receiver.onReceiveAborted(error)
        }
    }
}

//---------------------------------------------------------------------------

public class WebCacheDataReceiver : WebCacheReceiver {
    private var completion: ((WebCacheDataReceiver) -> Void)?
    private var acceptPartial: Bool
    private var sizeLimit: Int64
    
    public var url: String
    public var info: WebCacheInfo?
    public var offset: Int64?
    public var length: Int64?
    public var buffer: NSMutableData?
    public var error: NSError?
    public var response: NSURLResponse?
    public var progress: NSProgress?
    
    public init(url: String, acceptPartial: Bool = true, sizeLimit: Int? = nil, completion: ((WebCacheDataReceiver) -> Void)? = nil) {
        self.url = url
        self.completion = completion
        self.acceptPartial = acceptPartial
        self.sizeLimit = Int64(sizeLimit ?? Int.max)
    }
    
    public func onReceiveInited(response response: NSURLResponse?, progress: NSProgress?) {
        self.response = response
        self.progress = progress
    }

    public func onReceiveStarted(info: WebCacheInfo, offset: Int64, length: Int64?) {
        self.info = info
        self.offset = offset
        self.length = length
        
        var isValid = true
        if let length = length, totalLength = info.totalLength {
            isValid = length <= self.sizeLimit && (self.acceptPartial || length == totalLength)
        } else if !self.acceptPartial {
            isValid = false
        }
        
        if isValid {
            self.buffer = NSMutableData()
        } else {
            self.buffer = nil
            self.completion?(self)
            self.completion = nil
        }
    }
    
    public func onReceiveData(data: NSData) {
        if let buffer = self.buffer {
            if Int64(buffer.length) + Int64(data.length) > self.sizeLimit {
                self.buffer = nil
                self.completion?(self)
                self.completion = nil
            } else {
                buffer.appendData(data)
            }
        }
    }
    
    public func onReceiveFinished() {
        self.completion?(self)
        self.completion = nil
        self.buffer = nil
    }
    
    public func onReceiveAborted(error: NSError?) {
        self.error = error
        self.completion?(self)
        self.completion = nil
        self.buffer = nil
    }
}
