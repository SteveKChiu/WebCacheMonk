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

private let MIMETYPES: [String: String] = [
    "html": "text/html",
    "htm": "text/html",
    "xml": "text/xml",
    "css": "text/css",
    "js": "application/javascript",
    "jpg": "image/jpeg",
    "jpeg": "image/jpg",
    "png": "image/png",
    "gif": "image/gif",
]

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
    
    public func addMapping(url: String, imageNamed: String) {
        addMapping(url, entry: "asset://" + imageNamed)
    }

    public func addMapping(url: String, path: String) {
        var isDir: ObjCBool = false
        if NSFileManager.defaultManager().fileExistsAtPath(path, isDirectory: &isDir) {
            let path = !isDir || path.hasSuffix("/") ? path : path + "/"
            addMapping(url, entry: path)
        }
    }
    
    private func addMapping(url: String, entry: String) {
        dispatch_async(self.queue) {
            let mapping = (url: url, path: entry)
            if let index = self.mappings.indexOf({ $0.url == url }) {
                self.mappings[index] = mapping
            } else {
                self.mappings.append(mapping)
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
    
    private func getAssetData(path: String) -> NSData? {
        if !path.hasPrefix("asset://") {
            return nil
        }
        
        let path = path.substringFromIndex(path.startIndex.advancedBy(8))
        guard let r = path.rangeOfString(".", options: .BackwardsSearch) else {
            return nil
        }
        
        let name = path.substringToIndex(r.startIndex)
        guard let image = UIImage(named: name) else {
            return nil
        }
        
        let ext = path.substringFromIndex(r.endIndex)
        switch ext {
        case "jpg", "jpeg":
            return UIImageJPEGRepresentation(image, 1.0)
        
        case "png":
            return UIImagePNGRepresentation(image)
        
        default:
            return nil
        }
    }
    
    private func getFileSize(path: String) -> Int64? {
        guard let attributes = try? NSFileManager.defaultManager().attributesOfItemAtPath(path) else {
            return nil
        }
        if attributes[NSFileType] as? String == NSFileTypeDirectory {
            return nil
        } else {
            return (attributes[NSFileSize] as? NSNumber)?.longLongValue
        }
    }
    
    private func getMimeType(path: String) -> String {
        let ext = (path as NSString).pathExtension
        if let mimetype = MIMETYPES[ext] {
            return mimetype
        }
        
        let UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext, nil)!
        if let UTIMimeType = UTTypeCopyPreferredTagWithClass(UTI.takeUnretainedValue(), kUTTagClassMIMEType) {
            return UTIMimeType.takeUnretainedValue() as String
        }
        
        return "application/octet-stream"
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .Default, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        dispatch_async(self.queue) {
            receiver.onReceiveInited(response: nil, progress: progress)
        
            guard let path = self.getPath(url) else {
                receiver.onReceiveAborted(nil)
                return
            }
            
            var assetData: NSData?
            let totalLength: Int64
            if let data = self.getAssetData(path) {
                assetData = data
                totalLength = Int64(data.length)
            } else if let fileSize = self.getFileSize(path) {
                totalLength = fileSize
            } else {
                receiver.onReceiveAborted(WebCacheError("WebCacheMonk.InvalidResource", url: url))
                return
            }
            
            let offset = offset ?? 0
            var length = length ?? (totalLength - offset)
            
            guard offset + length <= totalLength else {
                receiver.onReceiveAborted(WebCacheError("WebCacheMonk.InvalidRange", url: url))
                return
            }
            
            let info = WebCacheInfo(mimeType: self.getMimeType(path))
            info.totalLength = totalLength

            if let assetData = assetData {
                self.transferData(info, data: assetData, offset: offset, length: length, progress: progress, receiver: receiver)
            } else {
                guard let input = NSFileHandle(forReadingAtPath: path) else {
                    receiver.onReceiveAborted(WebCacheError("WebCacheMonk.InvalidResource", url: url))
                    return
                }
                
                defer {
                    input.closeFile()
                }
                
                self.transferFile(info, file: input, offset: offset, length: length, progress: progress, receiver: receiver)
            }
        }
    }

    private func transferData(info: WebCacheInfo, data: NSData, offset: Int64, length: Int64, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        if progress?.totalUnitCount < 0 {
            progress?.totalUnitCount = length
        }

        receiver.onReceiveStarted(info, offset: offset, length: length)
        
        if let totalLength = info.totalLength where length < totalLength {
            let data = data.subdataWithRange(NSRange(Int(offset) ..< Int(offset + length)))
            receiver.onReceiveData(data)
        } else {
            receiver.onReceiveData(data)
        }
        
        progress?.completedUnitCount += length
        receiver.onReceiveFinished()
    }

    private func transferFile(info: WebCacheInfo, file: NSFileHandle, offset: Int64, length: Int64, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        if progress?.totalUnitCount < 0 {
            progress?.totalUnitCount = length
        }

        receiver.onReceiveStarted(info, offset: offset, length: length)
        file.seekToFileOffset(UInt64(offset))
        
        var length = length
        while length > 0 {
            let size = min(65536, length)
            let data = file.readDataOfLength(Int(size))
            receiver.onReceiveData(data)
            progress?.completedUnitCount += size
            length -= size
        }

        receiver.onReceiveFinished()
    }

    public func peek(url: String, completion: (WebCacheInfo?, Int64?) -> Void) {
        dispatch_async(self.queue) {
            guard let path = self.getPath(url) else {
                completion(nil, nil)
                return
            }
            
            let totalLength: Int64
            if let data = self.getAssetData(path) {
                totalLength = Int64(data.length)
            } else if let fileSize = self.getFileSize(path) {
                totalLength = fileSize
            } else {
                completion(nil, nil)
                return
            }
            
            let info = WebCacheInfo(mimeType: self.getMimeType(path))
            info.totalLength = totalLength
            completion(info, totalLength)
        }
    }
}

