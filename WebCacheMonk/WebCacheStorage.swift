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
    public var policy: WebCachePolicy
    
    public init(mimeType: String?, policy: WebCachePolicy = .default) {
        self.policy = policy
        super.init(mimeType: mimeType)
    }

    public init(from: WebCacheInfo, policy: WebCachePolicy = .default) {
        self.policy = policy
        super.init(from: from)
    }
}

//---------------------------------------------------------------------------

public protocol WebCacheInputStream : class {
    var length: Int64 { get }
    func read(_ length: Int) throws -> Data?
    func close()
}

public protocol WebCacheOutputStream : class {
    func write(_ data: Data) throws
    func close()
}

//---------------------------------------------------------------------------

public protocol WebCacheStorageAdapter : class {
    func getPath(_ url: String) -> (path: String, tag: [String: Any]?)
    func addGroup(_ url: String, tag: [String: Any]?)
    func removeGroup(_ url: String)
    
    func getSize(_ path: String) -> Int64?
    func getMeta(_ path: String) -> WebCacheStorageInfo?
    func setMeta(_ path: String, meta: WebCacheStorageInfo)

    func openInputStream(_ path: String, tag: [String: Any]?, offset: Int64, length: Int64?) throws -> (info: WebCacheStorageInfo, input: WebCacheInputStream)?
    func openOutputStream(_ path: String, tag: [String: Any]?, meta: WebCacheStorageInfo, offset: Int64) throws -> WebCacheOutputStream?
    
    func remove(_ path: String)
    func removeExpired()
    func removeAll()
}

public extension WebCacheStorageAdapter {
    public var fileManager: FileManager {
        return FileManager.default()
    }

    public func getUrlHash(_ url: String) -> String {
        return WebCacheMD5(url)
    }

    public func getSize(_ path: String) -> Int64? {
        do {
            let attributes = try self.fileManager.attributesOfItem(atPath: path)
            return (attributes[FileAttributeKey.size.rawValue] as? NSNumber)?.int64Value
        } catch {
            return nil
        }
    }

    public func getMeta(_ path: String) -> WebCacheStorageInfo? {
        let size = getxattr(path, "WebCache", nil, 0, 0, 0)
        if size <= 0 {
            return nil
        }
        
        do {
            let data = NSMutableData(length: size)!
            getxattr(path, "WebCache", data.mutableBytes, size, 0, 0)
            let json = try JSONSerialization.jsonObject(with: data as Data, options: [])
            
            let meta = WebCacheStorageInfo(mimeType: json["m"] as? String)
            meta.textEncoding = json["t"] as? String
            meta.totalLength = (json["l"] as? NSNumber)?.int64Value
            meta.policy = .Description(json["p"] as? String)
            if let headers = json["h"] as? [String: String] {
                meta.headers = headers
            }
            
            if meta.policy.isExpired {
                _ = try? self.fileManager.removeItem(atPath: path)
                return nil
            }
            return meta
        } catch {
            return nil
        }
    }
    
    public func setMeta(_ path: String, meta: WebCacheStorageInfo) {
        var json = [String: AnyObject]()
        json["m"] = meta.mimeType
        if let textEncoding = meta.textEncoding {
            json["t"] = textEncoding
        }
        if let totalLength = meta.totalLength {
            json["l"] = NSNumber(value: totalLength)
        }
        json["p"] = meta.policy.description
        json["h"] = meta.headers
        
        do {
            if !self.fileManager.fileExists(atPath: path) {
                self.fileManager.createFile(atPath: path, contents: nil, attributes: nil)
            }
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            setxattr(path, "WebCache", (data as NSData).bytes, data.count, 0, 0)
        } catch {
            NSLog("fail to set meta info, error = %@", error as NSError)
        }
    }

    public func remove(_ path: String) {
        _ = try? self.fileManager.removeItem(atPath: path)
    }
}

//---------------------------------------------------------------------------

public class WebCacheStorage : WebCacheMutableStore {
    private var queue: DispatchQueue
    private var adapter: WebCacheStorageAdapter
    
    public init(adapter: WebCacheStorageAdapter) {
        self.queue = DispatchQueue(label: "WebCacheStorage", attributes: .serial)
        self.adapter = adapter
    }
    
    public func perform(_ block: () -> Void) {
        self.queue.async(execute: block)
    }
    
    public func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, receiver: WebCacheReceiver) {
        perform() {
            do {
                receiver.onReceiveInited(response: nil, progress: progress)
                let offset = offset ?? 0

                let (file, tag) = self.adapter.getPath(url)
                guard let (meta, input) = try self.adapter.openInputStream(file, tag: tag, offset: offset, length: length) else {
                    receiver.onReceiveAborted(nil)
                    return;
                }
                
                defer {
                    input.close()
                }
                
                var length = input.length
                if progress?.totalUnitCount < 0 {
                    if meta.totalLength == offset + length {
                        progress?.totalUnitCount = meta.totalLength!
                        progress?.completedUnitCount = offset
                    } else {
                        progress?.totalUnitCount = length
                    }
                }
                
                if progress?.isCancelled == true {
                    receiver.onReceiveAborted(nil)
                    return;
                }
                
                receiver.onReceiveStarted(meta, offset: offset, length: length)
                
                while length > 0 {
                    if progress?.isCancelled == true {
                        receiver.onReceiveAborted(nil)
                        return;
                    }
                    
                    let size = Int(min(length, 65536))
                    guard let data = try input.read(size) else {
                        break
                    }
                    
                    receiver.onReceiveData(data)
                    length -= data.count
                    progress?.completedUnitCount += Int64(data.count)
                }
                
                receiver.onReceiveFinished()
            } catch {
                receiver.onReceiveAborted(error as NSError)
            }
        }
    }

    public func peek(_ url: String, completion: (WebCacheInfo?, Int64?) -> Void) {
        peek(url) {
            info, fileSize, filePath in
            completion(info, fileSize)
        }
    }
    
    public func peek(_ url: String, completion: (WebCacheInfo?, Int64?, String?) -> Void) {
        perform() {
            let (path, _) = self.adapter.getPath(url)
            if let fileSize = self.adapter.getSize(path),
                   info = self.adapter.getMeta(path) {
                completion(info, fileSize, path)
            } else {
                completion(nil, nil, nil)
            }
        }
    }

    public func store(_ url: String, policy: WebCachePolicy = .default) -> WebCacheReceiver? {
        return WebCacheStorageReceiver(url: url, policy: policy, store: self)
    }
    
    public func change(_ url: String, policy: WebCachePolicy) {
        perform() {
            let (path, _) = self.adapter.getPath(url)
            if let meta = self.adapter.getMeta(path) where meta.policy != policy {
                meta.policy = policy
                self.adapter.setMeta(path, meta: meta)
            }
        }
    }
    
    public func remove(_ url: String) {
        perform() {
            let (path, _) = self.adapter.getPath(url)
            self.adapter.remove(path)
        }
    }
        
    public func removeExpired() {
        perform() {
            self.adapter.removeExpired()
        }
    }

    public func removeAll() {
        perform() {
            self.adapter.removeAll()
        }
    }
    
    public func addGroup(_ url: String, policy: WebCachePolicy = .default) {
        addGroup(url, tag: ["policy": policy])
    }

    public func addGroup(_ url: String, tag: [String: Any]?) {
        perform() {
            self.adapter.addGroup(url, tag: tag)
        }
    }

    public func removeGroup(_ url: String) {
        perform() {
            self.adapter.removeGroup(url)
        }
    }
}

//---------------------------------------------------------------------------

private class WebCacheStorageReceiver : WebCacheReceiver {
    private var store: WebCacheStorage
    private var semaphore: DispatchSemaphore
    private var policy: WebCachePolicy
    private var url: String
    private var output: WebCacheOutputStream?
    
    init(url: String, policy: WebCachePolicy, store: WebCacheStorage) {
        self.url = url
        self.policy = policy
        self.store = store
        self.semaphore = DispatchSemaphore(value: 4)
    }
    
    func onReceiveInited(response: URLResponse?, progress: Progress?) {
        // do nothing
    }

    func onReceiveStarted(_ info: WebCacheInfo, offset: Int64, length: Int64?) {
        self.store.perform() {
            do {
                let adapter = self.store.adapter
                let (path, tag) = adapter.getPath(self.url)
                
                if case WebCachePolicy.default = self.policy {
                    if let policy = tag?["policy"] as? WebCachePolicy {
                        self.policy = policy
                    }
                }
                
                if !self.policy.isExpired {
                    let meta = WebCacheStorageInfo(from: info, policy: self.policy)
                    self.output = try adapter.openOutputStream(path, tag: tag, meta: meta, offset: offset)
                }
            } catch {
                NSLog("fail to open file for %@, error = %@", self.url, error as NSError)
            }
        }
    }
    
    func onReceiveData(_ data: Data) {
        // to avoid the sender dump the data too fast, to reduce memory usage
        _ = self.semaphore.wait(timeout: DispatchTime.now() + 1)
        
        self.store.perform() {
            do {
                try self.output?.write(data)
            } catch {
                NSLog("fail to write file, error = %@", error as NSError)
                self.output?.close()
                self.output = nil
            }
            
            self.semaphore.signal()
        }
    }
    
    func onReceiveFinished() {
        self.store.perform() {
            self.output?.close()
            self.output = nil
        }
    }
    
    func onReceiveAborted(_ error: NSError?) {
        self.store.perform() {
            if let error = error {
                NSLog("fail to receive file for %@, error = %@", self.url, error)
            }
            self.output?.close()
            self.output = nil
        }
    }
}
