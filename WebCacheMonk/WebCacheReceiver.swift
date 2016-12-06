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

open class WebCacheInfo {
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
    func onReceiveInited(response: URLResponse?, progress: Progress?)
    
    func onReceiveStarted(_ info: WebCacheInfo, offset: Int64, length: Int64?)
    func onReceiveData(_ data: Data)
    func onReceiveFinished()
    
    func onReceiveAborted(_ error: Error?)
}

//---------------------------------------------------------------------------

open class WebCacheFilter : WebCacheReceiver {
    private let receiver: WebCacheReceiver
    private var filter: WebCacheReceiver?
    private var progress: Progress?
    private var completion: ((Bool, Error?, Progress?) -> Bool)?
        
    public init(_ receiver: WebCacheReceiver, filter: WebCacheReceiver? = nil, completion: ((Bool, Error?, Progress?) -> Bool)? = nil) {
        self.receiver = receiver
        self.filter = filter
        self.completion = completion
    }
    
    open func onReceiveInited(response: URLResponse?, progress: Progress?) {
        self.progress = progress
        self.filter?.onReceiveInited(response: response, progress: progress)
        self.receiver.onReceiveInited(response: response, progress: progress)
    }

    open func onReceiveStarted(_ info: WebCacheInfo, offset: Int64, length: Int64?) {
        self.filter?.onReceiveStarted(info, offset: offset, length: length)
        self.receiver.onReceiveStarted(info, offset: offset, length: length)
    }
    
    open func onReceiveData(_ data: Data) {
        self.filter?.onReceiveData(data)
        self.receiver.onReceiveData(data)
    }
    
    open func onReceiveFinished() {
        if let completion = self.completion {
            self.completion = nil
            if completion(true, nil, self.progress) {
                return
            }
        }

        self.filter?.onReceiveFinished()
        self.receiver.onReceiveFinished()
    }
    
    open func onReceiveAborted(_ error: Error?) {
        if let completion = self.completion {
            self.completion = nil
            if completion(false, error, self.progress) {
                return
            }
        }

        self.filter?.onReceiveAborted(error)
        self.receiver.onReceiveAborted(error)
    }
}

//---------------------------------------------------------------------------

open class WebCacheDataReceiver : WebCacheReceiver {
    private var completion: ((WebCacheDataReceiver) -> Void)?
    private var acceptPartial: Bool
    private var sizeLimit: Int64
    
    open var url: String
    open var info: WebCacheInfo?
    open var offset: Int64?
    open var length: Int64?
    open var buffer: Data?
    open var error: Error?
    open var response: URLResponse?
    open var progress: Progress?
    
    public init(url: String, acceptPartial: Bool = true, sizeLimit: Int? = nil, completion: ((WebCacheDataReceiver) -> Void)? = nil) {
        self.url = url
        self.completion = completion
        self.acceptPartial = acceptPartial
        self.sizeLimit = Int64(sizeLimit ?? Int.max)
    }
    
    open func onReceiveInited(response: URLResponse?, progress: Progress?) {
        self.response = response
        self.progress = progress
    }

    open func onReceiveStarted(_ info: WebCacheInfo, offset: Int64, length: Int64?) {
        self.info = info
        self.offset = offset
        self.length = length
        
        var isValid = true
        if let length = length, let totalLength = info.totalLength {
            if length > self.sizeLimit {
                isValid = false
            } else if !self.acceptPartial && length != totalLength {
                isValid = false
            }
        } else if self.sizeLimit <= 0 {
            isValid = false
        } else if !self.acceptPartial {
            isValid = false
        }
        
        if isValid {
            self.buffer = Data()
        }
    }
    
    open func onReceiveData(_ data: Data) {
        if let buffer = self.buffer {
            if Int64(buffer.count) + Int64(data.count) > self.sizeLimit {
                self.buffer = nil
            } else {
                self.buffer!.append(data)
            }
        }
    }
    
    open func onReceiveFinished() {
        self.completion?(self)
        self.completion = nil
        self.buffer = nil
    }
    
    open func onReceiveAborted(_ error: Error?) {
        self.error = error
        self.buffer = nil
        self.completion?(self)
        self.completion = nil
    }
}
