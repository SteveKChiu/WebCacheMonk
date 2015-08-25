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
import MobileCoreServices

//---------------------------------------------------------------------------

public class WebCacheResourceStore : WebCacheStore {
    private var queue: dispatch_queue_t
    private var mappings = [(url: String, path: String)]()
    
    public init() {
        self.queue = dispatch_queue_create("WebCacheResourceStore", DISPATCH_QUEUE_SERIAL)
    }
    
    public convenience init(url: String, resource: String, bundle: NSBundle? = nil) {
        self.init()
        addMapping(url, resource: resource, bundle: bundle)
    }

    public convenience init(mappings: [(String, String)], bundle: NSBundle? = nil) {
        self.init()
        for (url, resource) in mappings {
            addMapping(url, resource: resource, bundle: bundle)
        }
    }

    public func addMapping(url: String, resource: String, bundle: NSBundle? = nil) {
        let name: String
        let ext: String
        if let r = resource.rangeOfString(".", options: .BackwardsSearch) {
            name = resource.substringToIndex(r.startIndex)
            ext = resource.substringFromIndex(r.endIndex.advancedBy(1))
        } else {
            name = resource
            ext = ""
        }
        
        let bundle = bundle ?? NSBundle.mainBundle()
        if let path = bundle.pathForResource(name, ofType: ext) {
            addMapping(url, path: path)
        }
    }
    
    public func addMapping(url: String, path: String) {
        var isDir: ObjCBool = false
        if NSFileManager.defaultManager().fileExistsAtPath(path, isDirectory: &isDir) {
            let path = !isDir || path.hasSuffix("/") ? path : path + "/"
            dispatch_async(self.queue) {
                let mapping = (url: url, path: path)
                if let index = self.mappings.indexOf({ $0.url == url }) {
                    self.mappings[index] = mapping
                } else {
                    self.mappings.append(mapping)
                }
            }
        }
    }

    public func removeMapping(url: String) {
        dispatch_async(self.queue) {
            if let index = self.mappings.indexOf({ $0.url == url }) {
                self.mappings.removeAtIndex(index)
            }
        }
    }
    
    private func getPath(url: String) -> String? {
        for (prefix, root) in self.mappings {
            if url.hasPrefix(prefix) {
                return root + url.substringFromIndex(url.startIndex.advancedBy(prefix.characters.count))
            }
        }
        return nil
    }
    
    private func getFileSize(path: String) -> Int64? {
        do {
            let attributes = try NSFileManager.defaultManager().attributesOfItemAtPath(path)
            if attributes[NSFileType] as? String == NSFileTypeDirectory {
                return nil
            } else {
                return (attributes[NSFileSize] as? NSNumber)?.longLongValue
            }
        } catch {
            return nil
        }
    }
    
    private func getMimeType(path: String) -> String {
        let UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (path as NSString).pathExtension, nil)!
        let UTIMimeType = UTTypeCopyPreferredTagWithClass(UTI.takeUnretainedValue(), kUTTagClassMIMEType)
        return (UTIMimeType?.takeUnretainedValue() ?? "application/octet-stream") as String
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, expired: WebCacheExpiration = .Default, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        dispatch_async(self.queue) {
            receiver.onReceiveInited(response: nil, progress: progress)
        
            guard let path = self.getPath(url),
                      fileSize = self.getFileSize(path) else {
                receiver.onReceiveAborted(nil)
                return
            }
            
            let offset = offset ?? 0
            var length = length ?? (fileSize - offset)
            
            guard offset + length <= fileSize else {
                receiver.onReceiveAborted(nil)
                return
            }
            
            guard let input = NSFileHandle(forReadingAtPath: path) else {
                receiver.onReceiveAborted(nil)
                return
            }
            
            defer {
                input.closeFile()
            }
            
            let info = WebCacheInfo(mimeType: self.getMimeType(path))
            info.totalLength = fileSize

            progress?.totalUnitCount = length
            receiver.onReceiveStarted(info, offset: offset, length: length)
            
            input.seekToFileOffset(UInt64(offset))
            while length > 0 {
                let size = min(65536, length)
                let data = input.readDataOfLength(Int(size))
                receiver.onReceiveData(data)
                progress?.completedUnitCount += size
                length -= size
            }
            
            receiver.onReceiveFinished()
        }
    }

    public func check(url: String, offset: Int64?, length: Int64?, completion: (Bool) -> Void) {
        dispatch_async(self.queue) {
            guard let path = self.getPath(url),
                      fileSize = self.getFileSize(path) else {
                completion(false)
                return
            }
            
            let offset = offset ?? 0
            let length = length ?? (fileSize - offset)
            completion(offset + length <= fileSize)
        }
    }
}

