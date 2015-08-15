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

public class WebCacheFileInputStream : WebCacheInputStream {
    private var handle: NSFileHandle
    private var limit: Int64
    
    public init(handle: NSFileHandle, limit: Int64) {
        self.handle = handle
        self.limit = limit
    }

    public var length: Int64 {
        return self.limit
    }
    
    public func read(length: Int) -> NSData? {
        let data = self.handle.readDataOfLength(length)
        return data.length == 0 ? nil : data
    }
    
    public func close() {
        self.handle.closeFile()
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileOutputStream : WebCacheOutputStream {
    private var handle: NSFileHandle

    public init(handle: NSFileHandle) {
        self.handle = handle
    }

    public func write(data: NSData) {
        self.handle.writeData(data)
    }
    
    public func close() {
        self.handle.truncateFileAtOffset(self.handle.offsetInFile)
        self.handle.closeFile()
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileStoreAdapter : WebCacheStorageAdapter {
    private var root: String
    private var groupMapping = [String: (String, WebCacheExpiration)]()
    private var groupOrder = [String]()
    
    public init(root: String) {
        do {
            self.root = root.hasSuffix("/") ? root : root + "/"
            try self.fileManager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("fail to create cache directory, error = %@", error as NSError)
        }
    }

    public func getPath(url: String) -> (path: String, defaultExpiration: WebCacheExpiration) {
        for group_url in self.groupOrder {
            if url.hasPrefix(group_url) {
                if let (root, expired) = self.groupMapping[group_url] {
                    return (root + getUrlHash(url), expired)
                }
            }
        }
        return (self.root + getUrlHash(url), .Default)
    }

    public func addGroup(url: String, expired: WebCacheExpiration) {
        let url = url.hasSuffix("/") ? url : url + "/"
        if self.groupMapping[url] != nil {
            return
        }
        let group = self.root + getUrlHash(url) + "/"
        
        self.groupMapping[url] = (group, expired)
        self.groupOrder.append(url)

        do {
            try self.fileManager.createDirectoryAtPath(group, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("fail to create cache group %@, error = %@", url, error as NSError)
        }
    }
    
    public func removeGroup(url: String) {
        let url = url.hasSuffix("/") ? url : url + "/"
        let group = self.root + getUrlHash(url) + "/"
        
        self.groupMapping.removeValueForKey(url)
        if let index = self.groupOrder.indexOf(url) {
            self.groupOrder.removeAtIndex(index)
        }
        
        remove(group)
    }

    public func getSize(path: String) -> Int64? {
        do {
            let file = NSURL(fileURLWithPath: path)
            var fileSizeValue: AnyObject?
            try file.getResourceValue(&fileSizeValue, forKey: NSURLFileSizeKey)
            return (fileSizeValue as? NSNumber)?.longLongValue
        } catch {
            return nil
        }
    }

    public func openInputStream(path: String, offset: Int64, length: Int64?) throws -> (info: WebCacheStorageInfo, input: WebCacheInputStream)? {
        guard let meta = getMeta(path) else {
            return nil
        }

        guard let input = NSFileHandle(forReadingAtPath: path) else {
            return nil
        }
        
        let fileSize = Int64(input.seekToEndOfFile())
        let offset = offset ?? 0
        let length = length ?? ((meta.totalLength ?? fileSize) - offset)
        
        if offset + length > fileSize {
            input.closeFile()
            return nil
        }
        
        input.seekToFileOffset(UInt64(offset))
        return (meta, WebCacheFileInputStream(handle: input, limit: length))
    }
    
    public func openOutputStream(path: String, meta: WebCacheStorageInfo, offset: Int64) throws -> WebCacheOutputStream? {
        if let storedMeta = getMeta(path) {
            if meta != storedMeta && offset != 0 {
                remove(path)
                return nil
            }
        } else {
            if offset != 0 {
                return nil
            }
        }
        
        if offset == 0 {
            setMeta(path, meta: meta)
        }
        
        guard let handle = NSFileHandle(forWritingAtPath: path) else {
            return nil
        }
        
        if offset > 0 {
            let fileSize = handle.seekToEndOfFile()
            if UInt64(offset) > fileSize {
                handle.closeFile()
                return nil
            }
            
            handle.truncateFileAtOffset(UInt64(offset))
        }
        
        return WebCacheFileOutputStream(handle: handle)
    }

    public func removeAll() {
        do {
            self.groupMapping.removeAll()
            self.groupOrder.removeAll()
            try self.fileManager.removeItemAtPath(self.root)
            try self.fileManager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("fail to remove cache root, error = %@", error as NSError)
        }
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileStore : WebCacheStorage {
    public convenience init(name: String? = nil) {
        let name = name ?? "WebCache"
        let url = NSFileManager.defaultManager().URLsForDirectory(.CachesDirectory, inDomains: .UserDomainMask).first!
        let path = url.URLByAppendingPathComponent(name, isDirectory: true).path!
        self.init(path: path)
    }
    
    public init(path: String) {
        let adapter = WebCacheFileStoreAdapter(root: path)
        super.init(adapter: adapter)
    }
}

