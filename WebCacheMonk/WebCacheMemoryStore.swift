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

private class WebCacheDataInfo : NSObject {
    var mimeType: String?
    var textEncoding: String?
    var expiration: WebCacheExpiration
    var data: NSData
    
    init(mimeType: String?, textEncoding: String?, expired: WebCacheExpiration, data: NSData) {
        self.mimeType = mimeType
        self.textEncoding = textEncoding
        self.expiration = expired
        self.data = data
    }
}

//---------------------------------------------------------------------------

public class WebCacheMemoryStore : WebCacheStore {
    private var cache: NSCache
    
    public init(sizeLimit: Int = 4 * 1024 * 1024, countLimit: Int = 0) {
        self.cache = NSCache()
        self.cache.name = "WebCacheMemoryStore"
        self.cache.totalCostLimit = sizeLimit
        self.cache.countLimit = countLimit
    }
    
    public var totalCostLimit: Int {
        get {
            return self.cache.totalCostLimit
        }
        set {
            self.cache.totalCostLimit = newValue
        }
    }
    
    public var countLimit: Int {
        get {
            return self.cache.countLimit
        }
        set {
            self.cache.countLimit = newValue
        }
    }

    private func fetch(url: String, range: Range<Int>? = nil) -> (info: WebCacheDataInfo, data: NSData)? {
        guard let info = self.cache.objectForKey(url) as? WebCacheDataInfo else {
            return nil
        }
        
        guard !info.expiration.isExpired else {
            self.cache.removeObjectForKey(url)
            return nil
        }
        
        var data = info.data
        if let range = range {
            guard range.endIndex <= data.length else {
                return nil
            }
            
            if range.count < data.length {
                data = data.subdataWithRange(NSRange(range))
            }
        }
        
        return (info, data)
    }

    public func fetch(url: String, range: Range<Int>? = nil, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        guard let (info, data) = fetch(url, range: range) else {
            receiver.onReceiveError(nil, progress: progress)
            return
        }
        
        let response = NSURLResponse(URL: NSURL(string: url)!, MIMEType: info.mimeType, expectedContentLength: data.length, textEncodingName: info.textEncoding)
        
        progress?.totalUnitCount = Int64(data.length)
        receiver.onReceiveResponse(response, offset: range?.startIndex ?? 0, totalLength: info.data.length, progress: progress)
        
        receiver.onReceiveData(data, progress: progress)
        progress?.completedUnitCount += Int64(data.length)
        
        receiver.onReceiveEnd(progress: progress)
    }

    public func fetch(url: String, range: Range<Int>? = nil, progress: NSProgress? = nil, completion: (NSData?) -> Void) {
        guard let (_, data) = fetch(url, range: range) else {
            completion(nil)
            return
        }

        progress?.totalUnitCount = Int64(data.length)
        completion(data)
        progress?.completedUnitCount += Int64(data.length)
    }

    public func check(url: String, range: Range<Int>? = nil, completion: (Bool) -> Void) {
        guard let info = self.cache.objectForKey(url) as? WebCacheDataInfo else {
            completion(false)
            return
        }
        
        if info.expiration.isExpired {
            self.cache.removeObjectForKey(url)
            completion(false)
            return
        }

        if let range = range {
            completion(range.endIndex <= info.data.length)
        } else {
            completion(true)
        }
    }
    
    public func store(url: String, expired: WebCacheExpiration = .Default) -> WebCacheReceiver {
        return WebCacheDataReceiver(url: url, acceptPartial: false, sizeLimit: self.cache.totalCostLimit / 4) {
            receiver, progress in
            
            guard let buffer = receiver.buffer where progress?.cancelled != true else {
                return
            }
            
            let mimeType = receiver.response?.MIMEType
            let textEncoding = receiver.response?.textEncodingName
            self.store(url, mimeType: mimeType, textEncoding: textEncoding, expired: expired, data: NSData(data: buffer))
        }
    }
    
    public func store(url: String, mimeType: String?, textEncoding: String? = nil, expired: WebCacheExpiration = .Default, data: NSData) {
        if expired.isExpired {
            self.cache.removeObjectForKey(url)
            return
        }
        
        let info = WebCacheDataInfo(mimeType: mimeType, textEncoding: textEncoding, expired: expired, data: data)
        self.cache.setObject(info, forKey: url, cost: data.length)
    }
    
    public func change(url: String, expired: WebCacheExpiration) {
        if expired.isExpired {
            self.cache.removeObjectForKey(url)
        } else if let info = self.cache.objectForKey(url) as? WebCacheDataInfo {
            info.expiration = expired
        }
    }
    
    public func remove(url: String) {
        self.cache.removeObjectForKey(url)
    }
    
    public func removeAll() {
        self.cache.removeAllObjects()
    }
}

