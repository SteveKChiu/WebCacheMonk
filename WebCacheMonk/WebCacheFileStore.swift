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

public struct WebCacheFileMeta {
    public var mimeType: String?
    public var textEncoding: String?
    public var totalLength: Int
    public var expiration: WebCacheExpiration
}

public func == (lhs: WebCacheFileMeta, rhs: WebCacheFileMeta) -> Bool {
    return lhs.mimeType == rhs.mimeType
        && lhs.textEncoding == rhs.textEncoding
        && lhs.totalLength == rhs.totalLength
}

public func != (lhs: WebCacheFileMeta, rhs: WebCacheFileMeta) -> Bool {
    return !(lhs == rhs)
}

//---------------------------------------------------------------------------

public protocol WebCacheFileInput : class {
    var length: Int { get }
    func read(length: Int) throws -> NSData?
    func close()
}

public protocol WebCacheFileOutput : class {
    func write(data: NSData) throws
    func close()
}

public protocol WebCacheFileStoreAdapter : class {
    func getPath(url: String) -> String
    func getMeta(path: String) -> WebCacheFileMeta?
    func setMeta(meta: WebCacheFileMeta, forPath: String)
    func openInput(path: String, range: Range<Int>?) throws -> (WebCacheFileMeta, WebCacheFileInput)?
    func openOutput(path: String, meta: WebCacheFileMeta, offset: Int) throws -> WebCacheFileOutput?
    func remove(path: String)
    func removeAll()
}

public extension WebCacheFileStoreAdapter {
    public var fileManager: NSFileManager {
        return NSFileManager.defaultManager()
    }

    public func getUrlHash(url: String) -> String {
        return WebCacheMD5(url)
    }

    public func getMeta(path: String) -> WebCacheFileMeta? {
        let size = getxattr(path, "WebCache", nil, 0, 0, 0)
        if size <= 0 {
            return nil
        }
        
        do {
            let data = NSMutableData(length: size)!
            getxattr(path, "WebCache", data.mutableBytes, size, 0, 0)
            let json = try NSJSONSerialization.JSONObjectWithData(data, options: [])
            let meta = WebCacheFileMeta(
                    mimeType: json["m"] as? String,
                    textEncoding: json["t"] as? String,
                    totalLength: (json["l"] as? NSNumber)?.integerValue ?? 0,
                    expiration: .Description(json["e"] as? String))
            if meta.expiration.isExpired {
                try self.fileManager.removeItemAtPath(path)
                return nil
            }
            return meta
        } catch {
            return nil
        }
    }
    
    public func setMeta(meta: WebCacheFileMeta, forPath path: String) {
        var json = [String: AnyObject]()
        if let mimeType = meta.mimeType {
            json["m"] = mimeType
        }
        if let textEncoding = meta.textEncoding {
            json["t"] = textEncoding
        }
        json["l"] = meta.totalLength
        json["e"] = meta.expiration.description
        
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

private class WebCacheFileHandleInput : WebCacheFileInput {
    var handle: NSFileHandle
    var limit: Int
    
    init(handle: NSFileHandle, limit: Int) {
        self.handle = handle
        self.limit = limit
    }

    var length: Int {
        return self.limit
    }
    
    func read(length: Int) -> NSData? {
        let data = self.handle.readDataOfLength(length)
        return data.length == 0 ? nil : data
    }
    
    func close() {
        self.handle.closeFile()
    }
}

private class WebCacheFileHandleOutput : WebCacheFileOutput {
    var handle: NSFileHandle

    init(handle: NSFileHandle) {
        self.handle = handle
    }

    func write(data: NSData) {
        self.handle.writeData(data)
    }
    
    func close() {
        self.handle.truncateFileAtOffset(self.handle.offsetInFile)
        self.handle.closeFile()
    }
}

public class WebCacheFileStoreDefaultAdapter: WebCacheFileStoreAdapter {
    var root: String
    
    public init(root: String) {
        do {
            self.root = root.hasSuffix("/") ? root : root + "/"
            try self.fileManager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("fail to create cache directory, error = %@", error as NSError)
        }
    }

    public func getPath(url: String) -> String {
        return self.root + self.getUrlHash(url)
    }

    public func openInput(path: String, range: Range<Int>?) -> (WebCacheFileMeta, WebCacheFileInput)? {
        guard let meta = self.getMeta(path) else {
            return nil
        }

        guard let input = NSFileHandle(forReadingAtPath: path) else {
            return nil
        }
        
        let fileSize = input.seekToEndOfFile()
        var offset = range?.startIndex ?? 0
        var limit = Int(fileSize)
        
        if let range = range {
            if UInt64(range.endIndex) > fileSize {
                input.closeFile()
                return nil
            }
            
            offset = range.startIndex
            limit = range.count
        } else {
            if UInt64(meta.totalLength) != fileSize {
                input.closeFile()
                return nil
            }
        }
        
        input.seekToFileOffset(UInt64(offset))
        return (meta, WebCacheFileHandleInput(handle: input, limit: limit))
    }
    
    public func openOutput(path: String, meta: WebCacheFileMeta, offset: Int) -> WebCacheFileOutput? {
        if let storedMeta = getMeta(path) {
            if meta != storedMeta {
                if offset == 0 {
                    setMeta(meta, forPath: path)
                } else {
                    remove(path)
                    return nil
                }
            }
        } else {
            if offset == 0 {
                setMeta(meta, forPath: path)
                if let handle = NSFileHandle(forWritingAtPath: path) {
                    return WebCacheFileHandleOutput(handle: handle)
                }
            }
            return nil
        }
        
        guard let handle = NSFileHandle(forWritingAtPath: path) else {
            return nil
        }
        
        let fileSize = handle.seekToEndOfFile()
        if UInt64(offset) > fileSize {
            handle.closeFile()
            return nil
        }
        
        handle.truncateFileAtOffset(UInt64(offset))
        return WebCacheFileHandleOutput(handle: handle)
    }

    public func removeAll() {
        do {
            try self.fileManager.removeItemAtPath(self.root)
            try self.fileManager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("fail to remove cache root, error = %@", error as NSError)
        }
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileStore : WebCacheStore {
    private var queue: dispatch_queue_t!
    private var adapter: WebCacheFileStoreAdapter
    
    public convenience init(name: String? = nil) {
        let name = name ?? "WebCache"
        let url = NSFileManager.defaultManager().URLsForDirectory(.CachesDirectory, inDomains: .UserDomainMask).first!
        let path = url.URLByAppendingPathComponent(name, isDirectory: true).path!
        self.init(path: path)
    }
    
    public convenience init(path: String) {
        let adapter = WebCacheFileStoreDefaultAdapter(root: path)
        self.init(adapter: adapter)
    }

    public init(adapter: WebCacheFileStoreAdapter) {
        self.queue = dispatch_queue_create("WebCacheFileStore", DISPATCH_QUEUE_SERIAL)
        self.adapter = adapter
    }
    
    public func fetch(url: String, range: Range<Int>? = nil, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        dispatch_async(self.queue) {
            do {
                let file = self.adapter.getPath(url)
                guard let (meta, input) = try self.adapter.openInput(file, range: range) else {
                    receiver.onReceiveError(nil, progress: progress)
                    return;
                }
                
                defer {
                    input.close()
                }
                
                let offset = range?.startIndex ?? 0
                var length = input.length
                
                progress?.totalUnitCount = Int64(length)
                if progress?.cancelled == true {
                    receiver.onReceiveError(nil, progress: progress)
                    return;
                }
                
                let response = NSURLResponse(URL: NSURL(string: url)!, MIMEType: meta.mimeType, expectedContentLength: length, textEncodingName: meta.textEncoding)
                receiver.onReceiveResponse(response, offset: offset, totalLength: meta.totalLength, progress: progress)
                
                while length > 0 {
                    if progress?.cancelled == true {
                        receiver.onReceiveError(nil, progress: progress)
                        return;
                    }
                    
                    guard let data = try input.read(min(length, 65536)) else {
                        break
                    }
                    
                    receiver.onReceiveData(data, progress: progress)
                    length -= data.length
                    progress?.completedUnitCount += Int64(data.length)
                }
                
                receiver.onReceiveEnd(progress: progress)
            } catch let error {
                receiver.onReceiveError(error as NSError, progress: progress)
            }
        }
    }

    public func check(url: String, range: Range<Int>? = nil, completion: (Bool) -> Void) {
        dispatch_async(self.queue) {
            do {
                let path = self.adapter.getPath(url)
                if self.adapter.getMeta(path) == nil {
                    completion(false)
                    return
                }
                
                let file = NSURL(fileURLWithPath: path)
                var fileSizeValue: AnyObject?
                try file.getResourceValue(&fileSizeValue, forKey: NSURLFileSizeKey)
                let fileSize = (fileSizeValue as! NSNumber).integerValue
                
                let start = range?.startIndex ?? 0
                let end = range?.endIndex ?? fileSize
                completion(start <= fileSize && end <= fileSize)
            } catch {
                completion(false)
            }
        }
    }
    
    public func store(url: String, expired: WebCacheExpiration = .Default) -> WebCacheReceiver {
        return WebCacheFileReceiver(url: url, expired: expired, store: self)
    }
    
    public func change(url: String, expired: WebCacheExpiration) {
        dispatch_async(self.queue) {
            let path = self.adapter.getPath(url)
            if var meta = self.adapter.getMeta(path) {
                meta.expiration = expired
                self.adapter.setMeta(meta, forPath: path)
            }
        }
    }
    
    public func remove(url: String) {
        dispatch_async(self.queue) {
            let path = self.adapter.getPath(url)
            self.adapter.remove(path)
        }
    }
        
    public func removeAll() {
        dispatch_async(self.queue) {
            self.adapter.removeAll()
        }
    }
}

//---------------------------------------------------------------------------

private class WebCacheFileReceiver : WebCacheReceiver {
    private var adapter: WebCacheFileStoreAdapter
    private var queue: dispatch_queue_t!
    private var expiration: WebCacheExpiration
    private var url: String
    private var output: WebCacheFileOutput?
    
    init(url: String, expired: WebCacheExpiration, store: WebCacheFileStore) {
        self.url = url
        self.expiration = expired
        self.adapter = store.adapter
        self.queue = store.queue
    }
        
    func onReceiveResponse(response: NSURLResponse, offset: Int, totalLength: Int, progress: NSProgress?) {
        dispatch_async(self.queue) {
            do {
                let path = self.adapter.getPath(self.url)
                let meta = WebCacheFileMeta(mimeType: response.MIMEType, textEncoding: response.textEncodingName, totalLength: totalLength, expiration: self.expiration)
                self.output = try self.adapter.openOutput(path, meta: meta, offset: offset)
            } catch {
                NSLog("fail to open file for %@, error = %@", self.url, error as NSError)
            }
        }
    }
    
    func onReceiveData(data: NSData, progress: NSProgress?) {
        dispatch_barrier_async(self.queue) {
            do {
                try self.output?.write(data)
            } catch {
                NSLog("fail to write file, error = %@", error as NSError)
                self.output?.close()
                self.output = nil
            }
        }
    }
    
    func onReceiveEnd(progress progress: NSProgress?) {
        dispatch_async(self.queue) {
            self.output?.close()
            self.output = nil
        }
    }
    
    func onReceiveError(error: NSError?, progress: NSProgress?) {
        dispatch_async(self.queue) {
            if let error = error {
                NSLog("fail to receive file for %@, error = %@", self.url, error)
            }
            self.output?.close()
            self.output = nil
            
            let path = self.adapter.getPath(self.url)
            self.adapter.remove(path)
        }
    }
}

