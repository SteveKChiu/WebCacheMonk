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

open class WebCacheResourceStore : WebCacheStore {
    private var queue: DispatchQueue
    private var mappings = [(url: String, path: String)]()
    
    public init() {
        self.queue = DispatchQueue(label: "WebCacheResourceStore", attributes: [])
    }
    
    public convenience init(url: String, resource: String, bundle: Bundle? = nil) {
        self.init()
        addMapping(url, resource: resource, bundle: bundle)
    }

    public convenience init(mappings: [(String, String)], bundle: Bundle? = nil) {
        self.init()
        for (url, resource) in mappings {
            addMapping(url, resource: resource, bundle: bundle)
        }
    }

    open func addMapping(_ url: String, resource: String, bundle: Bundle? = nil) {
        let name: String
        let ext: String
        if let r = resource.range(of: ".", options: .backwards) {
            name = resource.substring(to: r.lowerBound)
            ext = resource.substring(from: resource.index(after: r.upperBound))
        } else {
            name = resource
            ext = ""
        }
        
        let bundle = bundle ?? Bundle.main
        if let path = bundle.path(forResource: name, ofType: ext) {
            addMapping(url, path: path)
        }
    }
    
    open func addMapping(_ url: String, imageNamed: String) {
        addMapping(url, entry: "asset://" + imageNamed)
    }

    open func addMapping(_ url: String, path: String) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let path = !isDir.boolValue || path.hasSuffix("/") ? path : path + "/"
            addMapping(url, entry: path)
        }
    }
    
    private func addMapping(_ url: String, entry: String) {
        self.queue.async {
            let mapping = (url: url, path: entry)
            if let index = self.mappings.index(where: { $0.url == url }) {
                self.mappings[index] = mapping
            } else {
                self.mappings.append(mapping)
            }
        }
    }

    open func removeMapping(_ url: String) {
        self.queue.async {
            if let index = self.mappings.index(where: { $0.url == url }) {
                self.mappings.remove(at: index)
            }
        }
    }
    
    private func getPath(_ url: String) -> String? {
        for (prefix, root) in self.mappings {
            if url.hasPrefix(prefix) {
                return root + url.substring(from: url.characters.index(url.startIndex, offsetBy: prefix.characters.count))
            }
        }
        return nil
    }
    
    private func getAssetData(_ path: String) -> Data? {
        if !path.hasPrefix("asset://") {
            return nil
        }
        
        let path = path.substring(from: path.characters.index(path.startIndex, offsetBy: 8))
        guard let r = path.range(of: ".", options: .backwards) else {
            return nil
        }
        
        let name = path.substring(to: r.lowerBound)
        guard let image = UIImage(named: name) else {
            return nil
        }
        
        let ext = path.substring(from: r.upperBound)
        switch ext {
        case "jpg", "jpeg":
            return UIImageJPEGRepresentation(image, 1.0)
        
        case "png":
            return UIImagePNGRepresentation(image)
        
        default:
            return nil
        }
    }
    
    private func getFileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        if let attr = attributes[FileAttributeKey.type] as? FileAttributeType, attr == FileAttributeType.typeDirectory {
            return nil
        } else {
            return attributes[FileAttributeKey.size] as? Int64
        }
    }
    
    private func getMimeType(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        if let mimetype = MIMETYPES[ext] {
            return mimetype
        }
        
        let UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, nil)!
        if let UTIMimeType = UTTypeCopyPreferredTagWithClass(UTI.takeUnretainedValue(), kUTTagClassMIMEType) {
            return UTIMimeType.takeUnretainedValue() as String
        }
        
        return "application/octet-stream"
    }

    open func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, receiver: WebCacheReceiver) {
        self.queue.async {
            receiver.onReceiveInited(response: nil, progress: progress)
        
            guard let path = self.getPath(url) else {
                receiver.onReceiveAborted(nil)
                return
            }
            
            var assetData: Data?
            let totalLength: Int64
            if let data = self.getAssetData(path) {
                assetData = data
                totalLength = Int64(data.count)
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
                guard let input = FileHandle(forReadingAtPath: path) else {
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

    private func setupProgress(_ progress: Progress?, info: WebCacheInfo, offset: Int64, length: Int64) {
        if let progress = progress, progress.totalUnitCount < 0 {
            if info.totalLength == offset + length {
                progress.totalUnitCount = info.totalLength!
                progress.completedUnitCount = offset
            } else {
                progress.totalUnitCount = length
            }
        }
    }

    private func transferData(_ info: WebCacheInfo, data: Data, offset: Int64, length: Int64, progress: Progress? = nil, receiver: WebCacheReceiver) {
        setupProgress(progress, info: info, offset: offset, length: length)

        receiver.onReceiveStarted(info, offset: offset, length: length)
        
        if let totalLength = info.totalLength, length < totalLength {
            let data = data.subdata(in: Int(offset) ..< Int(offset + length))
            receiver.onReceiveData(data)
        } else {
            receiver.onReceiveData(data)
        }
        
        progress?.completedUnitCount += length
        receiver.onReceiveFinished()
    }

    private func transferFile(_ info: WebCacheInfo, file: FileHandle, offset: Int64, length: Int64, progress: Progress? = nil, receiver: WebCacheReceiver) {
        setupProgress(progress, info: info, offset: offset, length: length)

        receiver.onReceiveStarted(info, offset: offset, length: length)
        file.seek(toFileOffset: UInt64(offset))
        
        var length = length
        while length > 0 {
            let size = min(65536, length)
            let data = file.readData(ofLength: Int(size))
            receiver.onReceiveData(data)
            progress?.completedUnitCount += size
            length -= size
        }

        receiver.onReceiveFinished()
    }

    open func peek(_ url: String, completion: @escaping (WebCacheInfo?, Int64?) -> Void) {
        self.queue.async {
            guard let path = self.getPath(url) else {
                completion(nil, nil)
                return
            }
            
            let totalLength: Int64
            if let data = self.getAssetData(path) {
                totalLength = Int64(data.count)
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

