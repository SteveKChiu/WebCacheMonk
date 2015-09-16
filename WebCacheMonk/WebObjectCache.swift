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
    private let cache = NSCache()
    private let dataSource: WebCacheSource
    
    public var dataDecoder: DataDecoder
    public var costEvaluator: CostEvaluator?
    
    public typealias DataDecoder = (NSData, options: [String: Any]?, completion: (OBJECT?) -> Void) -> Void
    public typealias CostEvaluator = (OBJECT) -> Int
    
    public init(name: String? = nil, configuration: NSURLSessionConfiguration? = nil, decoder: DataDecoder) {
        self.dataSource = WebCacheFileStore(name: name) | WebCacheFetcher(configuration: configuration)
        self.dataDecoder = decoder
        self.cache.name = name ?? "WebObjectCache"
    }

    public init(path: String, configuration: NSURLSessionConfiguration? = nil, decoder: DataDecoder) {
        self.dataSource = WebCacheFileStore(path: path) | WebCacheFetcher(configuration: configuration)
        self.dataDecoder = decoder
        self.cache.name = "WebObjectCache"
    }

    public init(source: WebCacheSource, decoder: DataDecoder) {
        self.dataSource = source
        self.dataDecoder = decoder
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
    
    private func getKey(url: String, tag: String?) -> String {
        if let tag = tag {
            return "\(tag)@\(url)"
        } else {
            return url
        }
    }
    
    public func fetch(url: String, tag: String? = nil, options: [String: Any]? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, completion: (OBJECT?) -> Void) {
        if let object = self.cache.objectForKey(getKey(url, tag: tag)) {
            if let wrapper = object as? WebObjectWrapper {
                completion(wrapper.value as? OBJECT)
            } else {
                completion(object as? OBJECT)
            }
            return
        }
    
        let receiver = WebCacheDataReceiver(url: url) {
            receiver in
            
            guard let data = receiver.buffer else {
                completion(nil)
                return
            }
            
            self.dataDecoder(data, options: options) {
                object in
                
                if let object = object {
                    self.store(url, tag: tag, object: object)
                }
                
                completion(object)
            }
        }
        
        self.dataSource.fetch(url, offset: nil, length: nil, expired: expired, progress: progress, receiver: receiver)
    }
    
    public func store(url: String, tag: String? = nil, object: OBJECT) {
        let cost = self.costEvaluator?(object) ?? 0
        if let object = object as? AnyObject {
            self.cache.setObject(object, forKey: getKey(url, tag: tag), cost: cost)
        } else {
            self.cache.setObject(WebObjectWrapper(object), forKey: getKey(url, tag: tag), cost: cost)
        }
    }
    
    public func change(url: String, tag: String? = nil, expired: WebCacheExpiration) {
        if expired.isExpired {
            self.remove(url, tag: tag)
        } else if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.change(url, expired: expired)
        }
    }
    
    public func remove(url: String, tag: String? = nil) {
        self.cache.removeObjectForKey(getKey(url, tag: tag))
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.remove(url)
        }
    }
    
    public func removeAll() {
        self.cache.removeAllObjects()
        if let sourceStore = self.dataSource as? WebCacheMutableStore {
            sourceStore.removeAll()
        }
    }
}

//---------------------------------------------------------------------------

private class WebObjectWrapper : NSObject {
    var value: Any
    
    init(_ value: Any) {
        self.value = value
    }
}
