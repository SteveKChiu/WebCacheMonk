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

public protocol WebCacheSource : class {
    func fetch(url: String, offset: Int64?, length: Int64?, expired: WebCacheExpiration, progress: NSProgress?, receiver: WebCacheReceiver)
}

public extension WebCacheSource {
    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, completion: (NSData?) -> Void) {
        self.fetch(url, offset: offset, length: length, expired: expired, progress: progress, receiver: WebCacheDataReceiver(url: url) {
            receiver in
            
            completion(receiver.buffer)
        })
    }
}

//---------------------------------------------------------------------------

public protocol WebCacheStore : WebCacheSource {
    func check(url: String, offset: Int64?, length: Int64?, completion: (Bool) -> Void)
}

//---------------------------------------------------------------------------

public protocol WebCacheMutableStore : WebCacheStore {
    func store(url: String, expired: WebCacheExpiration) -> WebCacheReceiver?
    func change(url: String, expired: WebCacheExpiration)
    func remove(url: String)
    func removeAll()
}

public extension WebCacheMutableStore {
    public func store(url: String, info: WebCacheInfo, expired: WebCacheExpiration, data: NSData) {
        if let receiver = self.store(url, expired: expired) {
            receiver.onReceiveInited(response: nil, progress: nil)
            receiver.onReceiveStarted(info, offset: 0, length: Int64(data.length))
            receiver.onReceiveData(data)
            receiver.onReceiveFinished()
        }
    }
}

//---------------------------------------------------------------------------

public class WebCache : WebCacheMutableStore {
    private var dataStore: WebCacheStore
    private var dataSource: WebCacheSource?

    public convenience init(name: String? = nil, memoryLimit: Int = 0, configuration: NSURLSessionConfiguration? = nil) {
        let store = WebCacheMemoryStore(sizeLimit: memoryLimit)
        let source = WebCacheFileStore(name: name) | WebCacheFetcher(configuration: configuration)
        self.init(store: store, source: source)
    }

    public convenience init(path: String, memoryLimit: Int = 0, configuration: NSURLSessionConfiguration? = nil) {
        let store = WebCacheMemoryStore(sizeLimit: memoryLimit)
        let source = WebCacheFileStore(path: path) | WebCacheFetcher(configuration: configuration)
        self.init(store: store, source: source)
    }

    public init(store: WebCacheStore, source: WebCacheSource? = nil) {
        self.dataStore = store
        self.dataSource = source
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        self.dataStore.fetch(url, offset: offset, length: length, expired: expired, progress: progress, receiver: WebCacheFilter(receiver) {
            progress in
            
            receiver.onReceiveInited(response: nil, progress: progress)
            
            if progress?.cancelled == true {
                receiver.onReceiveAborted(nil)
                return
            }
            
            guard let dataSource = self.dataSource else {
                receiver.onReceiveAborted(nil)
                return
            }
            
            var receiver = receiver
            if let dataStore = self.dataStore as? WebCacheMutableStore,
                   storeReceiver = dataStore.store(url, expired: expired) {
                receiver = WebCacheFilter(receiver, filter: storeReceiver)
            }
            
            dataSource.fetch(url, offset: offset, length: length, expired: expired, progress: progress, receiver: receiver)
        })
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil) {
        self.check(url, offset: offset, length: length) {
            found in
            
            if !found {
                return
            }
            
            guard let dataSource = self.dataSource,
                      dataStore = self.dataStore as? WebCacheMutableStore,
                      storeReceiver = dataStore.store(url, expired: expired) else {
                return
            }

            dataSource.fetch(url, offset: offset, length: length, expired: expired, progress: progress, receiver: storeReceiver)
        }
    }

    public func check(url: String, offset: Int64? = nil, length: Int64? = nil, completion: (Bool) -> Void) {
        self.dataStore.check(url, offset: offset, length: length) {
            found in
            
            if found {
                completion(true)
            } else if let sourceStore = self.dataSource as? WebCacheStore {
                sourceStore.check(url, offset: offset, length: length, completion: completion)
            } else {
                completion(false)
            }
        }
    }

    public func store(url: String, expired: WebCacheExpiration = .Default) -> WebCacheReceiver? {
        let dataStore = self.dataStore as? WebCacheMutableStore
        return dataStore?.store(url, expired: expired)
    }

    public func store(url: String, info: WebCacheInfo, expired: WebCacheExpiration = .Default, data: NSData) {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.store(url, info: info, expired: expired, data: data)
        }
    }

    public func change(url: String, expired: WebCacheExpiration) {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.change(url, expired: expired)
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.change(url, expired: expired)
        }
    }

    public func remove(url: String) {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.remove(url)
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.remove(url)
        }
    }
    
    public func removeAll() {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.removeAll()
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.removeAll()
        }
    }

    public func connect(source: WebCacheSource) {
        if let cache = self.dataSource as? WebCache {
            cache.connect(source)
        } else if let store = self.dataSource as? WebCacheStore {
            self.dataSource = WebCache(store: store, source: source)
        } else if let sourceCache = source as? WebCache {
            self.dataSource = sourceCache
        } else if let sourceStore = source as? WebCacheStore {
            self.dataSource = WebCache(store: sourceStore, source: self.dataSource)
        } else {
            self.dataSource = source
        }
    }
}

public func | (lhs: WebCacheStore, rhs: WebCacheSource) -> WebCache {
    if let cache = lhs as? WebCache {
        cache.connect(rhs)
        return cache
    } else {
        return WebCache(store: lhs, source: rhs)
    }
}

