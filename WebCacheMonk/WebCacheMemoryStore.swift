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

private let DEFAULT_SIZE_LIMIT = 128 * 1024 * 1024

//---------------------------------------------------------------------------

private class WebCacheDataInfo : NSObject {
    var meta: WebCacheStorageInfo
    var data: NSData
    
    init(from: WebCacheInfo, expired: WebCacheExpiration, data: NSData) {
        self.meta = WebCacheStorageInfo(from: from, expired: expired)
        self.data = NSData(data: data)
    }
}

//---------------------------------------------------------------------------

public class WebCacheMemoryStore : WebCacheMutableStore {
    private var queue: dispatch_queue_t
    private var cache: NSCache
    
    public init(sizeLimit: Int = DEFAULT_SIZE_LIMIT, countLimit: Int = 0) {
        self.queue = dispatch_queue_create("WebCacheMemoryStore", DISPATCH_QUEUE_SERIAL)
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

    private func fetch(url: String, offset: Int64?, length: Int64?) -> (info: WebCacheDataInfo, data: NSData)? {
        guard let info = self.cache.objectForKey(url) as? WebCacheDataInfo else {
            return nil
        }
        
        guard !info.meta.expiration.isExpired else {
            self.cache.removeObjectForKey(url)
            return nil
        }
        
        let offset = offset ?? 0
        let length = length ?? (Int64(info.data.length) - offset)
        
        guard offset + length <= Int64(info.data.length) else {
            return nil
        }
        
        let data: NSData
        if length < Int64(info.data.length) {
            data = info.data.subdataWithRange(NSRange(Int(offset) ..< Int(offset + length)))
        } else {
            data = info.data
        }
        
        return (info, data)
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        dispatch_async(self.queue) {
            receiver.onReceiveInited(response: nil, progress: progress)
        
            guard let (info, data) = self.fetch(url, offset: offset, length: length) else {
                receiver.onReceiveAborted(nil)
                return
            }
        
            let offset = offset ?? 0
            let length = Int64(data.length)
        
            if progress?.totalUnitCount < 0 {
                progress?.totalUnitCount = length
            }

            receiver.onReceiveStarted(info.meta, offset: offset, length: length)
        
            receiver.onReceiveData(data)
            progress?.completedUnitCount += length
        
            receiver.onReceiveFinished()
        }
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, completion: (NSData?) -> Void) {
        dispatch_async(self.queue) {
            guard let (_, data) = self.fetch(url, offset: offset, length: length) else {
                completion(nil)
                return
            }

            let length = Int64(data.length)
            if progress?.totalUnitCount < 0 {
                progress?.totalUnitCount = length
            }
            
            completion(data)
            progress?.completedUnitCount += length
        }
    }

    public func check(url: String, offset: Int64? = nil, length: Int64? = nil, completion: (Int64?) -> Void) {
        dispatch_async(self.queue) {
            guard let info = self.cache.objectForKey(url) as? WebCacheDataInfo else {
                completion(nil)
                return
            }
        
            if info.meta.expiration.isExpired {
                self.cache.removeObjectForKey(url)
                completion(nil)
                return
            }

            let totalLength = Int64(info.data.length)
            let offset = offset ?? 0
            let length = length ?? (totalLength - offset)
            if offset + length <= totalLength {
                completion(totalLength)
            } else {
                completion(nil)
            }
        }
    }
    
    public func store(url: String, expired: WebCacheExpiration = .Default) -> WebCacheReceiver? {
        return WebCacheDataReceiver(url: url, acceptPartial: false, sizeLimit: self.cache.totalCostLimit / 4) {
            receiver in
            
            guard let buffer = receiver.buffer, info = receiver.info
                    where receiver.progress?.cancelled != true else {
                return
            }
            
            self.store(url, info: info, expired: expired, data: NSData(data: buffer))
        }
    }
    
    public func store(url: String, info: WebCacheInfo, expired: WebCacheExpiration = .Default, data: NSData) {
        dispatch_barrier_async(self.queue) {
            if expired.isExpired {
                self.cache.removeObjectForKey(url)
                return
            }
        
            let info = WebCacheDataInfo(from: info, expired: expired, data: data)
            self.cache.setObject(info, forKey: url, cost: data.length)
        }
    }
    
    public func change(url: String, expired: WebCacheExpiration) {
        dispatch_async(self.queue) {
            if expired.isExpired {
                self.cache.removeObjectForKey(url)
            } else if let info = self.cache.objectForKey(url) as? WebCacheDataInfo {
                info.meta.expiration = expired
            }
        }
    }
    
    public func removeExpired() {
        // not supported
    }
    
    public func remove(url: String) {
        dispatch_async(self.queue) {
            self.cache.removeObjectForKey(url)
        }
    }
    
    public func removeAll() {
        dispatch_async(self.queue) {
            self.cache.removeAllObjects()
        }
    }
}

