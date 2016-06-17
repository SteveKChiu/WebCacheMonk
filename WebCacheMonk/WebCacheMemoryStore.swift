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
    var data: Data
    
    init(from: WebCacheInfo, policy: WebCachePolicy, data: Data) {
        self.meta = WebCacheStorageInfo(from: from, policy: policy)
        self.data = data
    }
}

//---------------------------------------------------------------------------

public class WebCacheMemoryStore : WebCacheMutableStore {
    private var queue: DispatchQueue
    private var cache: Cache<AnyObject, AnyObject>
    
    public init(sizeLimit: Int = DEFAULT_SIZE_LIMIT, countLimit: Int = 0) {
        self.queue = DispatchQueue(label: "WebCacheMemoryStore", attributes: .serial)
        self.cache = Cache()
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

    private func fetch(_ url: String, offset: Int64?, length: Int64?) -> (info: WebCacheDataInfo, data: Data)? {
        guard let info = self.cache.object(forKey: url) as? WebCacheDataInfo else {
            return nil
        }
        
        guard !info.meta.policy.isExpired else {
            self.cache.removeObject(forKey: url)
            return nil
        }
        
        let offset = offset ?? 0
        let length = length ?? (Int64(info.data.count) - offset)
        
        guard offset + length <= Int64(info.data.count) else {
            return nil
        }
        
        let data: Data
        if length < Int64(info.data.count) {
            data = info.data.subdata(in: Int(offset) ..< Int(offset + length))
        } else {
            data = info.data
        }
        
        return (info, data)
    }

    private func setupProgress(_ progress: Progress?, info: WebCacheInfo, offset: Int64, length: Int64) {
        if progress?.totalUnitCount < 0 {
            if info.totalLength == offset + length {
                progress?.totalUnitCount = info.totalLength!
                progress?.completedUnitCount = offset
            } else {
                progress?.totalUnitCount = length
            }
        }
    }

    public func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, receiver: WebCacheReceiver) {
        self.queue.async {
            receiver.onReceiveInited(response: nil, progress: progress)
        
            guard let (info, data) = self.fetch(url, offset: offset, length: length) else {
                receiver.onReceiveAborted(nil)
                return
            }
        
            let offset = offset ?? 0
            let length = Int64(data.count)
            self.setupProgress(progress, info: info.meta, offset: offset, length: length)

            receiver.onReceiveStarted(info.meta, offset: offset, length: length)
        
            receiver.onReceiveData(data)
            progress?.completedUnitCount += length
        
            receiver.onReceiveFinished()
        }
    }

    public func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, completion: (WebCacheInfo?, Data?) -> Void) {
        self.queue.async {
            guard let (info, data) = self.fetch(url, offset: offset, length: length) else {
                completion(nil, nil)
                return
            }

            let offset = offset ?? 0
            let length = Int64(data.count)
            self.setupProgress(progress, info: info.meta, offset: offset, length: length)
            
            completion(info.meta, data)
            progress?.completedUnitCount += length
        }
    }

    public func peek(_ url: String, completion: (WebCacheInfo?, Int64?) -> Void) {
        self.queue.async {
            guard let info = self.cache.object(forKey: url) as? WebCacheDataInfo else {
                completion(nil, nil)
                return
            }
        
            if info.meta.policy.isExpired {
                self.cache.removeObject(forKey: url)
                completion(nil, nil)
                return
            }

            completion(info.meta, Int64(info.data.count))
        }
    }
    
    public func store(_ url: String, policy: WebCachePolicy = .default) -> WebCacheReceiver? {
        return WebCacheDataReceiver(url: url, acceptPartial: false, sizeLimit: self.cache.totalCostLimit / 4) {
            receiver in
            
            if let buffer = receiver.buffer, info = receiver.info where receiver.progress?.isCancelled != true {
                self.store(url, info: info, policy: policy, data: buffer)
            }
        }
    }
    
    public func store(_ url: String, info: WebCacheInfo, policy: WebCachePolicy = .default, data: Data) {
        self.queue.async {
            if policy.isExpired {
                self.cache.removeObject(forKey: url)
                return
            }
        
            let info = WebCacheDataInfo(from: info, policy: policy, data: data)
            self.cache.setObject(info, forKey: url, cost: data.count)
        }
    }
    
    public func change(_ url: String, policy: WebCachePolicy) {
        self.queue.async {
            if policy.isExpired {
                self.cache.removeObject(forKey: url)
            } else if let info = self.cache.object(forKey: url) as? WebCacheDataInfo {
                info.meta.policy = policy
            }
        }
    }
    
    public func removeExpired() {
        // not supported
    }
    
    public func remove(_ url: String) {
        self.queue.async {
            self.cache.removeObject(forKey: url)
        }
    }
    
    public func removeAll() {
        self.queue.async {
            self.cache.removeAllObjects()
        }
    }
}

