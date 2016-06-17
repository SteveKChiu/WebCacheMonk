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
    private var queue: DispatchQueue
    private let cache = Cache<NSString, WebObjectEntry>()
    private let dataSource: WebCacheSource
    
    public var decoder: ObjectDecoder?
    public var evaluator: ObjectEvaluator?
    
    public typealias ObjectDecoder = (Data, options: [String: Any]?, completion: (OBJECT?) -> Void) -> Void
    public typealias ObjectEvaluator = (OBJECT) -> Int
    
    public init(name: String? = nil, configuration: URLSessionConfiguration? = nil, decoder: ObjectDecoder?) {
        self.queue = DispatchQueue(label: "WebObjectCache", attributes: .serial)
        self.dataSource = WebCacheFileStore(name: name) | WebCacheFetcher(configuration: configuration)
        self.decoder = decoder
        self.cache.name = name ?? "WebObjectCache"
    }

    public init(path: String, configuration: URLSessionConfiguration? = nil, decoder: ObjectDecoder?) {
        self.queue = DispatchQueue(label: "WebObjectCache", attributes: .serial)
        self.dataSource = WebCacheFileStore(path: path) | WebCacheFetcher(configuration: configuration)
        self.decoder = decoder
        self.cache.name = "WebObjectCache"
    }

    public init(source: WebCacheSource, decoder: ObjectDecoder?) {
        self.queue = DispatchQueue(label: "WebObjectCache", attributes: .serial)
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
    
    public func decode(_ data: Data, options: [String: Any]?, completion: (OBJECT?) -> Void) {
        if let decoder = self.decoder {
            decoder(data, options: options, completion: completion)
        } else {
            completion(nil)
        }
    }
    
    public func evaluate(_ object: OBJECT) -> Int {
        return self.evaluator?(object) ?? 0
    }
    
    public func fetch(_ url: String, tag: String? = nil, options: [String: Any]? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, completion: (OBJECT?) -> Void) {
        self.queue.async {
            if let entry = self.cache.object(forKey: url) {
                if let object = entry.get(tag) as? OBJECT {
                    completion(object)
                    return
                }
            }
        
            let receiver = WebCacheDataReceiver(url: url) {
                receiver in
                
                guard let data = receiver.buffer else {
                    completion(nil)
                    return
                }
                
                self.decode(data as Data, options: options) {
                    object in
                    
                    if let object = object {
                        self.set(url, tag: tag, object: object)
                    }
                    
                    completion(object)
                }
            }
            
            self.dataSource.fetch(url, offset: nil, length: nil, policy: policy, progress: progress, receiver: receiver)
        }
    }
    
    public func get(_ url: String, tag: String? = nil) -> OBJECT? {
        var object: OBJECT?
        self.queue.sync {
            if let entry = self.cache.object(forKey: url) {
                object = entry.get(tag) as? OBJECT
            }
        }
        return object
    }
    
    public func set(_ url: String, tag: String? = nil, object: OBJECT) {
        self.queue.async {
            let cost = self.evaluate(object)
            if let entry = self.cache.object(forKey: url) {
                entry.set(tag, object: object, cost: cost)
                self.cache.setObject(entry, forKey: url, cost: entry.cost)
            } else {
                let entry = WebObjectEntry(tag: tag, object: object, cost: cost)
                self.cache.setObject(entry, forKey: url, cost: entry.cost)
            }
        }
    }
    
    public func change(_ url: String, policy: WebCachePolicy) {
        self.queue.async {
            if policy.isExpired {
                self.remove(url)
            } else if let sourceStore = self.dataSource as? WebCacheMutableStore {
                sourceStore.change(url, policy: policy)
            }
        }
    }
    
    public func remove(_ url: String, tag: String) {
        self.queue.async {
            if let entry = self.cache.object(forKey: url) {
                entry.remove(tag)
                self.cache.setObject(entry, forKey: url, cost: entry.cost)
            }
        }
    }

    public func remove(_ url: String) {
        self.queue.async {
            self.cache.removeObject(forKey: url)
            if let sourceStore = self.dataSource as? WebCacheMutableStore {
                sourceStore.remove(url)
            }
        }
    }
    
    public func removeAll() {
        self.queue.async {
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
    
    init(tag: String?, object: Any, cost: Int) {
        self.tags = [ (tag ?? ""): (object, cost) ]
        self.cost = cost
    }
    
    func get(_ tag: String?) -> Any? {
        if let r = self.tags[tag ?? ""] {
            return r.object
        }
        return nil
    }

    func set(_ tag: String?, object: Any, cost: Int) {
        let tag = tag ?? ""
        if let r = self.tags[tag] {
            self.cost -= r.cost
        }
        self.tags[tag] = (object, cost)
        self.cost += cost
    }
    
    func remove(_ tag: String) {
        if let r = self.tags.removeValue(forKey: tag) {
            self.cost -= r.cost
        }
    }
}
