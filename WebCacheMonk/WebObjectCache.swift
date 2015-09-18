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

public class WebObjectCache<OBJECT> {
    private var queue: dispatch_queue_t
    private let cache = NSCache()
    private let dataSource: WebCacheSource
    
    public var decoder: ObjectDecoder?
    public var evaluator: ObjectEvaluator?
    
    public typealias ObjectDecoder = (NSData, options: [String: Any]?, completion: (OBJECT?) -> Void) -> Void
    public typealias ObjectEvaluator = (OBJECT) -> Int
    
    public init(name: String? = nil, configuration: NSURLSessionConfiguration? = nil, decoder: ObjectDecoder?) {
        self.queue = dispatch_queue_create("WebObjectCache", DISPATCH_QUEUE_SERIAL)
        self.dataSource = WebCacheFileStore(name: name) | WebCacheFetcher(configuration: configuration)
        self.decoder = decoder
        self.cache.name = name ?? "WebObjectCache"
    }

    public init(path: String, configuration: NSURLSessionConfiguration? = nil, decoder: ObjectDecoder?) {
        self.queue = dispatch_queue_create("WebObjectCache", DISPATCH_QUEUE_SERIAL)
        self.dataSource = WebCacheFileStore(path: path) | WebCacheFetcher(configuration: configuration)
        self.decoder = decoder
        self.cache.name = "WebObjectCache"
    }

    public init(source: WebCacheSource, decoder: ObjectDecoder?) {
        self.queue = dispatch_queue_create("WebObjectCache", DISPATCH_QUEUE_SERIAL)
        self.dataSource = source
        self.decoder = decoder
        self.cache.name = "WebObjectCache"
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
    
    public func decode(data: NSData, options: [String: Any]?, completion: (OBJECT?) -> Void) {
        if let decoder = self.decoder {
            decoder(data, options: options, completion: completion)
        } else {
            completion(nil)
        }
    }
    
    public func evaluate(object: OBJECT) -> Int {
        return self.evaluator?(object) ?? 0
    }
    
    public func fetch(url: String, tag: String? = nil, options: [String: Any]? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, completion: (OBJECT?) -> Void) {
        dispatch_async(self.queue) {
            if let entry = self.cache.objectForKey(url) as? WebObjectEntry {
                let object = entry.get(tag)
                completion(object as? OBJECT)
                return
            }
        
            let receiver = WebCacheDataReceiver(url: url) {
                receiver in
                
                guard let data = receiver.buffer else {
                    completion(nil)
                    return
                }
                
                self.decode(data, options: options) {
                    object in
                    
                    if let object = object {
                        self.store(url, tag: tag, object: object)
                    }
                    
                    completion(object)
                }
            }
            
            self.dataSource.fetch(url, offset: nil, length: nil, expired: expired, progress: progress, receiver: receiver)
        }
    }
    
    public func store(url: String, tag: String? = nil, object: OBJECT) {
        dispatch_async(self.queue) {
            let cost = self.evaluate(object)
            if let entry = self.cache.objectForKey(url) as? WebObjectEntry {
                entry.set(tag, value: object, cost: cost)
                self.cache.setObject(entry, forKey: url, cost: entry.cost)
            } else {
                let entry = WebObjectEntry(tag: tag, value: object, cost: cost)
                self.cache.setObject(entry, forKey: url, cost: entry.cost)
            }
        }
    }
    
    public func change(url: String, expired: WebCacheExpiration) {
        dispatch_async(self.queue) {
            if expired.isExpired {
                self.remove(url)
            } else if let sourceStore = self.dataSource as? WebCacheMutableStore {
                sourceStore.change(url, expired: expired)
            }
        }
    }
    
    public func remove(url: String, tag: String) {
        dispatch_async(self.queue) {
            if let entry = self.cache.objectForKey(url) as? WebObjectEntry {
                entry.remove(tag)
                self.cache.setObject(entry, forKey: url, cost: entry.cost)
            }
        }
    }

    public func remove(url: String) {
        dispatch_async(self.queue) {
            self.cache.removeObjectForKey(url)
            if let sourceStore = self.dataSource as? WebCacheMutableStore {
                sourceStore.remove(url)
            }
        }
    }
    
    public func removeAll() {
        dispatch_async(self.queue) {
            self.cache.removeAllObjects()
            if let sourceStore = self.dataSource as? WebCacheMutableStore {
                sourceStore.removeAll()
            }
        }
    }
}

//---------------------------------------------------------------------------

private class WebObjectEntry : NSObject {
    var tags: [String: (object: Any, cost: Int)]
    var cost: Int
    
    init(tag: String?, value: Any, cost: Int) {
        self.tags = [ (tag ?? ""): (value, cost) ]
        self.cost = cost
    }
    
    func get(tag: String?) -> Any? {
        if let r = self.tags[tag ?? ""] {
            return r.object
        }
        return nil
    }

    func set(tag: String?, value: Any, cost: Int) {
        let tag = tag ?? ""
        if let r = self.tags[tag] {
            self.cost -= r.cost
        }
        self.tags[tag] = (value, cost)
        self.cost += cost
    }
    
    func remove(tag: String) {
        if let r = self.tags.removeValueForKey(tag) {
            self.cost -= r.cost
        }
    }
}
