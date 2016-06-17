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

public class WebCacheNullInputStream : WebCacheInputStream {
    public init() {
        // do nothing
    }

    public var length: Int64 {
        return 0
    }
    
    public func read(_ length: Int) -> Data? {
        return nil
    }
    
    public func close() {
        // do nothing
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileInputStream : WebCacheInputStream {
    private var handle: FileHandle
    private var limit: Int64
    
    public init(handle: FileHandle, limit: Int64) {
        self.handle = handle
        self.limit = limit
    }

    public var length: Int64 {
        return self.limit
    }
    
    public func read(_ length: Int) -> Data? {
        let data = self.handle.readData(ofLength: length)
        return data.count == 0 ? nil : data
    }
    
    public func close() {
        self.handle.closeFile()
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileOutputStream : WebCacheOutputStream {
    private var handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public func write(_ data: Data) {
        self.handle.write(data)
    }
    
    public func close() {
        self.handle.closeFile()
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileStoreAdapter : WebCacheStorageAdapter {
    private var root: String
    private var groups = [(url: String, root: String, tag: [String: Any]?)]()
    
    public init(root: String) {
        do {
            self.root = root.hasSuffix("/") ? root : root + "/"
            try self.fileManager.createDirectory(atPath: self.root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code != 516 {
                NSLog("fail to create cache directory, error = %@", error)
            }
        }
    }

    public func getPath(_ url: String) -> (path: String, tag: [String: Any]?) {
        for (group_url, root, tag) in self.groups {
            if url.hasPrefix(group_url) {
                return (root + getUrlHash(url), tag)
            }
        }
        return (self.root + getUrlHash(url), nil)
    }

    public func addGroup(_ url: String, tag: [String: Any]?) {
        let root = self.root + getUrlHash(url) + "/"
        let group = (url: url, root: root, tag: tag)

        if let index = self.groups.index(where: { $0.url == url }) {
            self.groups[index] = group
            return
        }
        
        self.groups.append(group)

        do {
            try self.fileManager.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code != 516 {
                NSLog("fail to create cache group %@, error = %@", url, error)
            }
        }
    }
    
    public func removeGroup(_ url: String) {
        if let index = self.groups.index(where: { $0.url == url }) {
            self.groups.remove(at: index)
        }
        
        let group = self.root + getUrlHash(url) + "/"
        remove(group)
    }

    public func openInputStream(_ path: String, tag: [String: Any]?, offset: Int64, length: Int64?) throws -> (info: WebCacheStorageInfo, input: WebCacheInputStream)? {
        guard let meta = getMeta(path) else {
            return nil
        }

        guard let input = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        
        let fileSize = Int64(input.seekToEndOfFile())
        let totalLength = meta.totalLength ?? fileSize
        let offset = offset ?? 0
        var length = length ?? (totalLength - offset)
        
        if length <= 0 {
            input.closeFile()
            return (meta, WebCacheNullInputStream())
        }
        
        if offset + length > fileSize {
            if let totalLength = meta.totalLength where totalLength <= fileSize {
                if offset < totalLength {
                    length = totalLength - offset
                } else {
                    input.closeFile()
                    return (meta, WebCacheNullInputStream())
                }
            } else {
                input.closeFile()
                return nil
            }
        }

        input.seek(toFileOffset: UInt64(offset))
        return (meta, WebCacheFileInputStream(handle: input, limit: length))
    }
    
    public func openOutputStream(_ path: String, tag: [String: Any]?, meta: WebCacheStorageInfo, offset: Int64) throws -> WebCacheOutputStream? {
        if offset == 0 {
            setMeta(path, meta: meta)
        } else if let storedMeta = getMeta(path) {
            if meta != storedMeta {
                remove(path)
                return nil
            }
        } else {
            return nil
        }
        
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return nil
        }
        
        if offset > 0 {
            let fileSize = handle.seekToEndOfFile()
            
            if UInt64(offset) > fileSize {
                handle.closeFile()
                return nil
            }
            
            handle.truncateFile(atOffset: UInt64(offset))
        }
        
        return WebCacheFileOutputStream(handle: handle)
    }

    public func removeExpired() {
        guard let enumerator = self.fileManager.enumerator(atPath: self.root) else {
            return
        }
        
        while let path = enumerator.nextObject() as? String {
            if let meta = getMeta(path) where meta.policy.isExpired {
                remove(path)
            }
        }
    }

    public func removeAll() {
        do {
            self.groups.removeAll()
            _ = try? self.fileManager.removeItem(atPath: self.root)
            try self.fileManager.createDirectory(atPath: self.root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code != 516 {
                NSLog("fail to init cache root, error = %@", error)
            }
        }
    }
}

//---------------------------------------------------------------------------

public class WebCacheFileStore : WebCacheStorage {
    public convenience init(name: String? = nil) {
        let name = name ?? "WebCache"
        let url = FileManager.default().urlsForDirectory(.cachesDirectory, inDomains: .userDomainMask).first!
        let path = try! url.appendingPathComponent(name, isDirectory: true).path!
        self.init(path: path)
    }
    
    public init(path: String) {
        let adapter = WebCacheFileStoreAdapter(root: path)
        super.init(adapter: adapter)
    }
}

