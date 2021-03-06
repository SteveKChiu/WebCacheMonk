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
    func fetch(_ url: String, offset: Int64?, length: Int64?, policy: WebCachePolicy, progress: Progress?, receiver: WebCacheReceiver)
}

public extension WebCacheSource {
    public func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, completion: @escaping (WebCacheInfo?, Data?) -> Void) {
        self.fetch(url, offset: offset, length: length, policy: policy, progress: progress, receiver: WebCacheDataReceiver(url: url) {
            receiver in
            completion(receiver.info, receiver.buffer)
        })
    }
}

//---------------------------------------------------------------------------

public protocol WebCacheStore : WebCacheSource {
    func peek(_ url: String, completion: @escaping (WebCacheInfo?, Int64?) -> Void)
}

//---------------------------------------------------------------------------

public protocol WebCacheMutableStore : WebCacheStore {
    func store(_ url: String, policy: WebCachePolicy) -> WebCacheReceiver?
    func change(_ url: String, policy: WebCachePolicy)
    func remove(_ url: String)
    func removeExpired()
    func removeAll()
}

public extension WebCacheMutableStore {
    public func store(_ url: String, info: WebCacheInfo, policy: WebCachePolicy, data: Data) {
        if let receiver = self.store(url, policy: policy) {
            receiver.onReceiveInited(response: nil, progress: nil)
            receiver.onReceiveStarted(info, offset: 0, length: Int64(data.count))
            receiver.onReceiveData(data)
            receiver.onReceiveFinished()
        }
    }
}

//---------------------------------------------------------------------------

func WebCacheError(_ domain: String, url: String?) -> Error {
    var userInfo: [AnyHashable: Any]?
    if let url = url {
        userInfo = [ NSURLErrorKey: URL(string: url)! ]
    }
    return NSError(domain: domain, code: 0, userInfo: userInfo)
}

//---------------------------------------------------------------------------

open class WebCache : WebCacheMutableStore {
    private var dataStore: WebCacheStore
    private var dataSource: WebCacheSource?

    public convenience init(name: String? = nil, memoryLimit: Int = 0, configuration: URLSessionConfiguration? = nil) {
        let store = WebCacheMemoryStore(sizeLimit: memoryLimit)
        let source = WebCacheFileStore(name: name) | WebCacheFetcher(configuration: configuration)
        self.init(store: store, source: source)
    }

    public convenience init(path: String, memoryLimit: Int = 0, configuration: URLSessionConfiguration? = nil) {
        let store = WebCacheMemoryStore(sizeLimit: memoryLimit)
        let source = WebCacheFileStore(path: path) | WebCacheFetcher(configuration: configuration)
        self.init(store: store, source: source)
    }

    public init(store: WebCacheStore, source: WebCacheSource? = nil) {
        self.dataStore = store
        self.dataSource = source
    }

    open func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, receiver: WebCacheReceiver) {
        if case .update = policy {
            self.fetchSource(url, offset: offset, length: length, policy: policy, progress: progress, receiver: receiver) {
                self.fetchStore(url, offset: offset, length: length, policy: policy, progress: progress, receiver: receiver, fallback: nil)
            }
        } else {
            self.fetchStore(url, offset: offset, length: length, policy: policy, progress: progress, receiver: receiver) {
                self.fetchSource(url, offset: offset, length: length, policy: policy, progress: progress, receiver: receiver, fallback: nil)
            }
        }
    }
    
    private func fetchStore(_ url: String, offset: Int64?, length: Int64?, policy: WebCachePolicy, progress: Progress?, receiver: WebCacheReceiver, fallback: (() -> Void)?) {
        var receiver = receiver
        if let fallback = fallback {
            receiver = WebCacheFilter(receiver) {
                found, error, progress in
                
                if found || error != nil || progress?.isCancelled == true {
                    return false
                } else {
                    fallback()
                    return true
                }
            }
        }

        self.dataStore.fetch(url, offset: offset, length: length, policy: policy, progress: progress, receiver: receiver)
    }

    private func fetchSource(_ url: String, offset: Int64?, length: Int64?, policy: WebCachePolicy, progress: Progress?, receiver: WebCacheReceiver, fallback: (() -> Void)?) {
        guard let dataSource = self.dataSource else {
            fallback?()
            return
        }
        
        var receiver = receiver
        if let dataStore = self.dataStore as? WebCacheMutableStore,
               let storeReceiver = dataStore.store(url, policy: policy) {
            receiver = WebCacheFilter(receiver, filter: storeReceiver)
        }
        
        if let fallback = fallback {
            receiver = WebCacheFilter(receiver) {
                found, error, progress in
                
                if found || error != nil || progress?.isCancelled == true {
                    return false
                } else {
                    fallback()
                    return true
                }
            }
        }
        
        dataSource.fetch(url, offset: offset, length: length, policy: policy, progress: progress, receiver: receiver)
    }

    open func prefetch(_ url: String, policy: WebCachePolicy = .default, progress: Progress? = nil, completion: ((Bool) -> Void)? = nil) {
        if case .update = policy {
            self.prefetchSource(url, offset: nil, length: nil, policy: policy, progress: progress, completion: completion) {
                self.prefetchStore(url, progress: progress, completion: completion) {
                    info, length in
                    completion?(false)
                }
            }
        } else {
            self.prefetchStore(url, progress: progress, completion: completion) {
                info, currentLength in
                var offset: Int64?
                var length: Int64?
                if let totalLength = info?.totalLength, let currentLength = currentLength {
                    offset = max(0, currentLength - 4096)
                    length = totalLength - offset!
                }
                self.prefetchSource(url, offset: offset, length: length, policy: policy, progress: progress, completion: completion) {
                    completion?(false)
                }
            }
        }
    }

    private func prefetchStore(_ url: String, progress: Progress?, completion: ((Bool) -> Void)?, fallback: @escaping (WebCacheInfo?, Int64?) -> Void) {
        self.peek(url) {
            info, length in
            
            if let totalLength = info?.totalLength, length == totalLength {
                if let totalUnitCount = progress?.totalUnitCount, totalUnitCount < 0 {
                    progress?.totalUnitCount = totalLength
                }
                progress?.completedUnitCount += totalLength
                completion?(true)
            } else {
                fallback(info, length)
            }
        }
    }

    private func prefetchSource(_ url: String, offset: Int64?, length: Int64?, policy: WebCachePolicy, progress: Progress?, completion: ((Bool) -> Void)?, fallback: @escaping () -> Void) {
        guard let dataSource = self.dataSource else {
            fallback()
            return
        }
        
        let receiver: WebCacheReceiver
        if let dataStore = self.dataStore as? WebCacheMutableStore,
               let storeReceiver = dataStore.store(url, policy: policy) {
            receiver = storeReceiver
        } else {
            receiver = WebCacheDataReceiver(url: url, sizeLimit: 0)
        }

        dataSource.fetch(url, offset: offset, length: length, policy: policy, progress: progress, receiver: WebCacheFilter(receiver) {
            found, error, progress in
            
            if found {
                completion?(true)
            } else {
                fallback()
            }
            return false
        })
    }
    
    open func peek(_ url: String, completion: @escaping (WebCacheInfo?, Int64?) -> Void) {
        self.dataStore.peek(url) {
            info, length in
            
            if let info = info, let length = length {
                completion(info, length)
            } else if let sourceStore = self.dataSource as? WebCacheStore {
                sourceStore.peek(url, completion: completion)
            } else {
                completion(nil, nil)
            }
        }
    }

    open func store(_ url: String, policy: WebCachePolicy = .default) -> WebCacheReceiver? {
        let dataStore = self.dataStore as? WebCacheMutableStore
        return dataStore?.store(url, policy: policy)
    }

    open func store(_ url: String, info: WebCacheInfo, policy: WebCachePolicy = .default, data: Data) {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.store(url, info: info, policy: policy, data: data)
        }
    }

    open func change(_ url: String, policy: WebCachePolicy) {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.change(url, policy: policy)
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.change(url, policy: policy)
        }
    }

    open func remove(_ url: String) {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.remove(url)
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.remove(url)
        }
    }
    
    open func removeExpired() {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.removeExpired()
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.removeExpired()
        }
    }

    open func removeAll() {
        if let dataStore = self.dataStore as? WebCacheMutableStore {
            dataStore.removeAll()
        }
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.removeAll()
        }
    }

    open func connect(_ source: WebCacheSource) {
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

