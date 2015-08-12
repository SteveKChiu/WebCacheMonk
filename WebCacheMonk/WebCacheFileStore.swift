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

private struct WebCacheFileInfo {
    var mimeType: String?
    var textEncoding: String?
    var totalLength: Int
    var expiration: WebCacheExpiration
    
    func isMatched(that: WebCacheFileInfo) -> Bool {
        return self.mimeType == that.mimeType
            && self.textEncoding == that.textEncoding
            && self.totalLength == that.totalLength
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileStore : WebCacheStore {
    private var queue: dispatch_queue_t!
    private var manager: NSFileManager
    private var root: String
    
    public convenience init(name: String? = nil) {
        let name = name ?? "WebCache"
        let url = NSFileManager.defaultManager().URLsForDirectory(.CachesDirectory, inDomains: .UserDomainMask).first!
        let path = url.URLByAppendingPathComponent(name, isDirectory: true).path!
        self.init(path: path)
    }
    
    public init(path: String) {
        self.queue = dispatch_queue_create("WebCacheFileStore", DISPATCH_QUEUE_SERIAL)
        self.manager = NSFileManager()
        self.root = path.hasSuffix("/") ? path : path + "/"
        
        do {
            try self.manager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil)
        } catch let error {
            NSLog("fail to create cache directory %@, error = %@", path, error as NSError)
        }
    }
    
    private func filePath(url: String) -> String {
        return self.root + MD5(url)
    }

    private func getMeta(path: String) -> WebCacheFileInfo? {
        let size = getxattr(path, "WebCache", nil, 0, 0, 0)
        if size <= 0 {
            return nil
        }
        
        do {
            let data = NSMutableData(length: size)!
            getxattr(path, "WebCache", data.mutableBytes, size, 0, 0)
            let json = try NSJSONSerialization.JSONObjectWithData(data, options: [])
            let info = WebCacheFileInfo(
                    mimeType: json["m"] as? String,
                    textEncoding: json["t"] as? String,
                    totalLength: (json["l"] as? NSNumber)?.integerValue ?? 0,
                    expiration: .Description(json["e"] as? String))
            
            if info.expiration.isExpired {
                try self.manager.removeItemAtPath(path)
                return nil
            }
            
            return info
        } catch {
            return nil
        }
    }
    
    private func setMeta(path: String, info: WebCacheFileInfo) {
        var json = [String: AnyObject]()
        if let mimeType = info.mimeType {
            json["m"] = mimeType
        }
        if let textEncoding = info.textEncoding {
            json["t"] = textEncoding
        }
        json["l"] = info.totalLength
        json["e"] = info.expiration.description
        
        do {
            let data = try NSJSONSerialization.dataWithJSONObject(json, options: [])
            setxattr(path, "WebCache", data.bytes, data.length, 0, 0)
        } catch let error {
            NSLog("fail to set meta info, error = %@", error as NSError)
        }
    }
    
    private func openInput(path: String, range: Range<Int>?) throws -> (WebCacheFileInfo, NSFileHandle, Range<Int>)? {
        guard let info = getMeta(path),
                  input = NSFileHandle(forReadingAtPath: path) else {
            return nil
        }
        
        let fileSize = input.seekToEndOfFile()
        var start = 0
        var end = Int(fileSize)
        
        if let range = range {
            if UInt64(range.endIndex) > fileSize {
                input.closeFile()
                return nil
            }
            
            start = range.startIndex
            end = range.endIndex
        } else {
            if UInt64(info.totalLength) != fileSize {
                input.closeFile()
                return nil
            }
        }
        
        input.seekToFileOffset(UInt64(start))
        return (info, input, start ..< end)
    }
    
    private func openOutput(path: String, info: WebCacheFileInfo, offset: Int) throws -> NSFileHandle? {
        if let meta = getMeta(path) {
            if !meta.isMatched(info) {
                if offset == 0 {
                    setMeta(path, info: info)
                    let output = NSFileHandle(forWritingAtPath: path)
                    output?.truncateFileAtOffset(0)
                    return output
                }
                
                try self.manager.removeItemAtPath(path)
                return nil
            }
        } else {
            if offset == 0 {
                self.manager.createFileAtPath(path, contents: nil, attributes: nil)
                setMeta(path, info: info)
                return NSFileHandle(forWritingAtPath: path)
            }
            return nil
        }
        
        guard let output = NSFileHandle(forWritingAtPath: path) else {
            return nil
        }
        
        let fileSize = output.seekToEndOfFile()
        if UInt64(offset) > fileSize {
            output.closeFile()
            return nil
        }
        
        output.truncateFileAtOffset(UInt64(offset))
        return output
    }

    public func fetch(url: String, range: Range<Int>? = nil, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        dispatch_async(self.queue) {
            do {
                let file = self.filePath(url)
                guard let (info, input, range) = try self.openInput(file, range: range) else {
                    receiver.onReceiveError(nil, progress: progress)
                    return;
                }
                
                defer {
                    input.closeFile()
                }
                
                progress?.totalUnitCount = Int64(range.count)
                if progress?.cancelled == true {
                    receiver.onReceiveError(nil, progress: progress)
                    return;
                }
                
                let response = NSURLResponse(URL: NSURL(string: url)!, MIMEType: info.mimeType, expectedContentLength: range.count, textEncodingName: info.textEncoding)
                receiver.onReceiveResponse(response, offset: range.startIndex, totalLength: info.totalLength, progress: progress)
                
                while true {
                    if progress?.cancelled == true {
                        receiver.onReceiveError(nil, progress: progress)
                        return;
                    }
                    
                    let data = input.readDataOfLength(65536)
                    if data.length > 0 {
                        receiver.onReceiveData(data, progress: progress)
                    } else {
                        break
                    }
                    
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
                let path = self.filePath(url)
                if self.getMeta(path) == nil {
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
            let path = self.filePath(url)
            if var meta = self.getMeta(path) {
                meta.expiration = expired
                self.setMeta(path, info: meta)
            }
        }
    }
    
    public func remove(url: String) {
        dispatch_async(self.queue) {
            do {
                let path = self.filePath(url)
                try self.manager.removeItemAtPath(path)
            } catch let error {
                NSLog("fail to remove %@, error = %@", url, error as NSError)
            }
        }
    }
        
    public func removeAll() {
        dispatch_async(self.queue) {
            do {
                try self.manager.removeItemAtPath(self.root)
                try self.manager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil)
            } catch let error {
                NSLog("fail to remove cache directory, error = %@", error as NSError)
            }
        }
    }
}

//---------------------------------------------------------------------------

private class WebCacheFileReceiver : WebCacheReceiver {
    private var store: WebCacheFileStore
    private var queue: dispatch_queue_t!
    private var expiration: WebCacheExpiration
    private var url: String
    private var output: NSFileHandle?
    
    init(url: String, expired: WebCacheExpiration, store: WebCacheFileStore) {
        self.url = url
        self.expiration = expired
        self.store = store
        self.queue = store.queue
    }
        
    func onReceiveResponse(response: NSURLResponse, offset: Int, totalLength: Int, progress: NSProgress?) {
        dispatch_async(self.queue) {
            do {
                let path = self.store.filePath(self.url)
                let info = WebCacheFileInfo(mimeType: response.MIMEType, textEncoding: response.textEncodingName, totalLength: totalLength, expiration: self.expiration)
                self.output = try self.store.openOutput(path, info: info, offset: offset)
            } catch let error {
                NSLog("fail to receive %@, error = %@", self.url, error as NSError)
            }
        }
    }
    
    func onReceiveData(data: NSData, progress: NSProgress?) {
        dispatch_barrier_async(self.queue) {
            self.output?.writeData(data)
        }
    }
    
    func onReceiveEnd(progress progress: NSProgress?) {
        dispatch_async(self.queue) {
            if let output = self.output {
                output.truncateFileAtOffset(output.offsetInFile)
                output.closeFile()
                self.output = nil
            }
        }
    }
    
    func onReceiveError(error: NSError?, progress: NSProgress?) {
        dispatch_async(self.queue) {
            if let error = error {
                NSLog("fail to receive %@, error = %@", self.url, error)
            }
            self.output = nil
            self.store.remove(self.url)
        }
    }
}

