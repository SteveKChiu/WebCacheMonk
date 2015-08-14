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

public class WebCacheStorageInfo : WebCacheInfo {
    public var expiration: WebCacheExpiration
    
    public init(mimeType: String?, expired: WebCacheExpiration = .Default) {
        self.expiration = expired
        super.init(mimeType: mimeType)
    }

    public init(from: WebCacheInfo, expired: WebCacheExpiration = .Default) {
        self.expiration = expired
        super.init(from: from)
    }
}

//---------------------------------------------------------------------------

public protocol WebCacheInputStream : class {
    var length: Int64 { get }
    func read(length: Int) throws -> NSData?
    func close()
}

public protocol WebCacheOutputStream : class {
    func write(data: NSData) throws
    func close()
}

//---------------------------------------------------------------------------

public protocol WebCacheStorageAdapter : class {
    func getPath(url: String) -> String
    
    func addGroup(url: String)
    func removeGroup(url: String)
    
    func getMeta(path: String) -> WebCacheStorageInfo?
    func setMeta(path: String, meta: WebCacheStorageInfo)
    
    func openInputStream(path: String, range: Range<Int64>?) throws -> (WebCacheStorageInfo, WebCacheInputStream)?
    func openOutputStream(path: String, meta: WebCacheStorageInfo, offset: Int64) throws -> WebCacheOutputStream?
    
    func remove(path: String)
    func removeAll()
}

public extension WebCacheStorageAdapter {
    public var fileManager: NSFileManager {
        return NSFileManager.defaultManager()
    }

    public func getUrlHash(url: String) -> String {
        return WebCacheMD5(url)
    }

    public func getMeta(path: String) -> WebCacheStorageInfo? {
        let size = getxattr(path, "WebCache", nil, 0, 0, 0)
        if size <= 0 {
            return nil
        }
        
        do {
            let data = NSMutableData(length: size)!
            getxattr(path, "WebCache", data.mutableBytes, size, 0, 0)
            let json = try NSJSONSerialization.JSONObjectWithData(data, options: [])
            
            let meta = WebCacheStorageInfo(mimeType: json["m"] as? String)
            meta.textEncoding = json["t"] as? String
            meta.totalLength = (json["l"] as? NSNumber)?.longLongValue
            meta.expiration = .Description(json["e"] as? String)
            if let headers = json["h"] as? [String: String] {
                meta.headers = headers
            }
            
            if meta.expiration.isExpired {
                try self.fileManager.removeItemAtPath(path)
                return nil
            }
            return meta
        } catch {
            return nil
        }
    }
    
    public func setMeta(path: String, meta: WebCacheStorageInfo) {
        var json = [String: AnyObject]()
        json["m"] = meta.mimeType
        if let textEncoding = meta.textEncoding {
            json["t"] = textEncoding
        }
        if let totalLength = meta.totalLength {
            json["l"] = NSNumber(longLong: totalLength)
        }
        json["e"] = meta.expiration.description
        json["h"] = meta.headers
        
        do {
            if !self.fileManager.fileExistsAtPath(path) {
                self.fileManager.createFileAtPath(path, contents: nil, attributes: nil)
            }
            let data = try NSJSONSerialization.dataWithJSONObject(json, options: [])
            setxattr(path, "WebCache", data.bytes, data.length, 0, 0)
        } catch {
            NSLog("fail to set meta info, error = %@", error as NSError)
        }
    }

    public func remove(path: String) {
        do {
            try self.fileManager.removeItemAtPath(path)
        } catch {
            NSLog("fail to remove cache file, error = %@", error as NSError)
        }
    }
}

//---------------------------------------------------------------------------

public class WebCacheStorage : WebCacheStore {
    private var queue: dispatch_queue_t
    private var adapter: WebCacheStorageAdapter
    
    public init(adapter: WebCacheStorageAdapter) {
        self.queue = dispatch_queue_create("WebCacheStorage", DISPATCH_QUEUE_SERIAL)
        self.adapter = adapter
    }
    
    public func perform(block: () -> Void) {
        dispatch_async(self.queue, block)
    }

    public func fetch(url: String, range: Range<Int64>? = nil, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        perform() {
            do {
                let file = self.adapter.getPath(url)
                guard let (meta, input) = try self.adapter.openInputStream(file, range: range) else {
                    receiver.onReceiveAborted(nil, progress: progress)
                    return;
                }
                
                defer {
                    input.close()
                }
                
                let offset = range?.startIndex ?? 0
                var length = input.length
                
                progress?.totalUnitCount = Int64(length)
                if progress?.cancelled == true {
                    receiver.onReceiveAborted(nil, progress: progress)
                    return;
                }
                
                receiver.onReceiveStarted(meta, offset: offset, length: length, progress: progress)
                
                while length > 0 {
                    if progress?.cancelled == true {
                        receiver.onReceiveAborted(nil, progress: progress)
                        return;
                    }
                    
                    let size = Int(min(length, 65536))
                    guard let data = try input.read(size) else {
                        break
                    }
                    
                    receiver.onReceiveData(data, progress: progress)
                    length -= data.length
                    progress?.completedUnitCount += Int64(data.length)
                }
                
                receiver.onReceiveFinished(progress: progress)
            } catch let error {
                receiver.onReceiveAborted(error as NSError, progress: progress)
            }
        }
    }

    public func check(url: String, range: Range<Int64>? = nil, completion: (Bool) -> Void) {
        perform() {
            do {
                let path = self.adapter.getPath(url)
                if self.adapter.getMeta(path) == nil {
                    completion(false)
                    return
                }
                
                let file = NSURL(fileURLWithPath: path)
                var fileSizeValue: AnyObject?
                try file.getResourceValue(&fileSizeValue, forKey: NSURLFileSizeKey)
                let fileSize = (fileSizeValue as! NSNumber).longLongValue
                
                let start = range?.startIndex ?? 0
                let end = range?.endIndex ?? fileSize
                completion(start <= fileSize && end <= fileSize)
            } catch {
                completion(false)
            }
        }
    }
    
    public func store(url: String, expired: WebCacheExpiration = .Default) -> WebCacheReceiver {
        return WebCacheStorageReceiver(url: url, expired: expired, store: self)
    }
    
    public func change(url: String, expired: WebCacheExpiration) {
        perform() {
            let path = self.adapter.getPath(url)
            if let meta = self.adapter.getMeta(path) {
                meta.expiration = expired
                self.adapter.setMeta(path, meta: meta)
            }
        }
    }
    
    public func remove(url: String) {
        perform() {
            let path = self.adapter.getPath(url)
            self.adapter.remove(path)
        }
    }
        
    public func removeAll() {
        perform() {
            self.adapter.removeAll()
        }
    }
    
    public func addGroup(url: String) {
        perform() {
            self.adapter.addGroup(url)
        }
    }

    public func removeGroup(url: String) {
        perform() {
            self.adapter.removeGroup(url)
        }
    }
}

//---------------------------------------------------------------------------

private class WebCacheStorageReceiver : WebCacheReceiver {
    private var store: WebCacheStorage
    private var semaphore: dispatch_semaphore_t
    private var expiration: WebCacheExpiration
    private var url: String
    private var output: WebCacheOutputStream?
    
    init(url: String, expired: WebCacheExpiration, store: WebCacheStorage) {
        self.url = url
        self.expiration = expired
        self.store = store
        self.semaphore = dispatch_semaphore_create(4)
    }
        
    func onReceiveStarted(info: WebCacheInfo, offset: Int64, length: Int64?, progress: NSProgress?) {
        self.store.perform() {
            do {
                let adapter = self.store.adapter
                let path = adapter.getPath(self.url)
                let meta = WebCacheStorageInfo(from: info, expired: self.expiration)
                self.output = try adapter.openOutputStream(path, meta: meta, offset: offset)
            } catch {
                NSLog("fail to open file for %@, error = %@", self.url, error as NSError)
            }
        }
    }
    
    func onReceiveData(data: NSData, progress: NSProgress?) {
        // to avoid the sender dump the data too fast, to reduce memory usage
        dispatch_semaphore_wait(self.semaphore, dispatch_time(DISPATCH_TIME_NOW, Int64(NSEC_PER_SEC)))
        
        self.store.perform() {
            do {
                try self.output?.write(data)
            } catch {
                NSLog("fail to write file, error = %@", error as NSError)
                self.output?.close()
                self.output = nil
            }
            
            dispatch_semaphore_signal(self.semaphore)
        }
    }
    
    func onReceiveFinished(progress progress: NSProgress?) {
        self.store.perform() {
            self.output?.close()
            self.output = nil
        }
    }
    
    func onReceiveAborted(error: NSError?, progress: NSProgress?) {
        self.store.perform() {
            if let error = error {
                NSLog("fail to receive file for %@, error = %@", self.url, error)
            }
            self.output?.close()
            self.output = nil
            
            let adapter = self.store.adapter
            let path = adapter.getPath(self.url)
            adapter.remove(path)
        }
    }
}
