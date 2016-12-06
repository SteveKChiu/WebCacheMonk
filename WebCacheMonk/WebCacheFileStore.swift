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

open class WebCacheNullInputStream : WebCacheInputStream {
    public init() {
        // do nothing
    }

    open var length: Int64 {
        return 0
    }
    
    open func read(_ length: Int) -> Data? {
        return nil
    }
    
    open func close() {
        // do nothing
    }
}

//---------------------------------------------------------------------------

open class WebCacheFileInputStream : WebCacheInputStream {
    private var handle: FileHandle
    private var limit: Int64
    
    public init(handle: FileHandle, limit: Int64) {
        self.handle = handle
        self.limit = limit
    }

    open var length: Int64 {
        return self.limit
    }
    
    open func read(_ length: Int) -> Data? {
        let data = self.handle.readData(ofLength: length)
        return data.count == 0 ? nil : data
    }
    
    open func close() {
        self.handle.closeFile()
    }
}

//---------------------------------------------------------------------------

open class WebCacheFileOutputStream : WebCacheOutputStream {
    private var handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    open func write(_ data: Data) {
        self.handle.write(data)
    }
    
    open func close() {
        self.handle.closeFile()
    }
}

//---------------------------------------------------------------------------

open class WebCacheFileStoreAdapter : WebCacheStorageAdapter {
    private var root: String
    private var groups = [(url: String, root: String, tag: [String: Any]?)]()
    
    public init(root: String) {
        do {
            self.root = root.hasSuffix("/") ? root : root + "/"
            try self.fileManager.createDirectory(atPath: self.root, withIntermediateDirectories: true, attributes: nil)
        } catch (let error as NSError) {
            if error.domain == NSCocoaErrorDomain && error.code != 516 {
                NSLog("fail to create cache directory, error = %@", error)
            }
        }
    }

    open func getPath(_ url: String) -> (path: String, tag: [String: Any]?) {
        for (group_url, root, tag) in self.groups {
            if url.hasPrefix(group_url) {
                return (root + getUrlHash(url), tag)
            }
        }
        return (self.root + getUrlHash(url), nil)
    }

    open func addGroup(_ url: String, tag: [String: Any]?) {
        let root = self.root + getUrlHash(url) + "/"
        let group = (url: url, root: root, tag: tag)

        if let index = self.groups.index(where: { $0.url == url }) {
            self.groups[index] = group
            return
        }
        
        self.groups.append(group)

        do {
            try self.fileManager.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: nil)
        } catch (let error as NSError) {
            if error.domain == NSCocoaErrorDomain && error.code != 516 {
                NSLog("fail to create cache group %@, error = %@", url, error)
            }
        }
    }
    
    open func removeGroup(_ url: String) {
        if let index = self.groups.index(where: { $0.url == url }) {
            self.groups.remove(at: index)
        }
        
        let group = self.root + getUrlHash(url) + "/"
        remove(group)
    }

    open func openInputStream(_ path: String, tag: [String: Any]?, offset: Int64, length: Int64?) throws -> (info: WebCacheStorageInfo, input: WebCacheInputStream)? {
        guard let meta = getMeta(path) else {
            return nil
        }

        guard let input = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        
        let fileSize = Int64(input.seekToEndOfFile())
        let totalLength = meta.totalLength ?? fileSize
        var length = length ?? (totalLength - offset)
        
        if length <= 0 {
            input.closeFile()
            return (meta, WebCacheNullInputStream())
        }
        
        if offset + length > fileSize {
            if let totalLength = meta.totalLength, totalLength <= fileSize {
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
    
    open func openOutputStream(_ path: String, tag: [String: Any]?, meta: WebCacheStorageInfo, offset: Int64) throws -> WebCacheOutputStream? {
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

    open func removeExpired() {
        guard let enumerator = self.fileManager.enumerator(atPath: self.root) else {
            return
        }
        
        while let path = enumerator.nextObject() as? String {
            if let meta = getMeta(path), meta.policy.isExpired {
                remove(path)
            }
        }
    }

    open func removeAll() {
        do {
            self.groups.removeAll()
            _ = try? self.fileManager.removeItem(atPath: self.root)
            try self.fileManager.createDirectory(atPath: self.root, withIntermediateDirectories: true, attributes: nil)
        } catch (let error as NSError) {
            if error.domain == NSCocoaErrorDomain && error.code != 516 {
                NSLog("fail to init cache root, error = %@", error)
            }
        }
    }
}

//---------------------------------------------------------------------------

open class WebCacheFileStore : WebCacheStorage {
    public convenience init(name: String? = nil) {
        let name = name ?? "WebCache"
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let path = url.appendingPathComponent(name, isDirectory: true).path
        self.init(path: path)
    }
    
    public init(path: String) {
        let adapter = WebCacheFileStoreAdapter(root: path)
        super.init(adapter: adapter)
    }
}

