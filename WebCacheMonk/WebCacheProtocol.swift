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

import UIKit

//---------------------------------------------------------------------------

public class WebCacheProtocol : NSURLProtocol {
    public class func prepareToFetch(request: NSURLRequest) -> (NSURL, WebCacheSource)? {
        return nil
    }

    public override final class func canInitWithRequest(request: NSURLRequest) -> Bool {
        guard NSURLProtocol.propertyForKey("WebCache", inRequest: request) == nil else {
            return false
        }
        
        return prepareToFetch(request) != nil
    }
    
    private var progress: NSProgress?
    private var hasRange = false
    
    public override func startLoading() {
        guard let client = self.client else {
            return
        }
        
        guard let (url, dataSource) = self.dynamicType.prepareToFetch(self.request) else {
            client.URLProtocol(self, didFailWithError: error("err.url"))
            return
        }
        
        self.progress = NSProgress(totalUnitCount: -1)
        self.hasRange = false
        
        var offset: Int64?
        var length: Int64?
        
        if let range = self.request.valueForHTTPHeaderField("Range") {
            self.hasRange = true
            let range = range as NSString
            
            let rex = try! NSRegularExpression(pattern: "bytes\\s*=\\s*(\\d+)\\-(\\d*)", options: [])
            let results = rex.matchesInString(range as String, options: [], range: NSRange(0 ..< range.length))
            
            if results[0].range.location != NSNotFound {
                offset = Int64(range.substringWithRange(results[0].range))!
            }
            
            if results[1].range.location != NSNotFound {
                let end = Int64(range.substringWithRange(results[1].range))!
                length = end - (offset ?? 0) + 1
            }
        }
        
        dataSource.fetch(url.absoluteString, offset: offset, length: length, expired: .Default, progress: self.progress, receiver: WebCacheProtocolReceiver(self))
    }
     
    public override func stopLoading() {
        self.progress?.cancel()
    }

    private func error(domain: String) -> NSError {
        let url = self.request.URL
        let userInfo: [NSObject : AnyObject]? = url != nil ? [NSURLErrorKey: url!] : nil
        return NSError(domain: domain, code: 0, userInfo: userInfo)
    }
}

//---------------------------------------------------------------------------

private class WebCacheProtocolReceiver : WebCacheReceiver {
    weak var handler: WebCacheProtocol?
    var serverResponse: NSHTTPURLResponse?
    var progress: NSProgress?

    init(_ handler: WebCacheProtocol) {
        self.handler = handler
    }

    func onReceiveInited(response response: NSURLResponse?, progress: NSProgress?) {
        self.serverResponse = response as? NSHTTPURLResponse
        self.progress = progress
    }
    
    func onReceiveStarted(info: WebCacheInfo, offset: Int64, length: Int64?) {
        guard let handler = self.handler else {
            return
        }
    
        var headers = [String: String]()
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Accept-Ranges"] = "bytes"
        headers["Cache-Control"] = "no-cache"
        headers["Content-Type"] = info.mimeType
        headers["Content-Encoding"] = "identity"
        
        for (k, v) in info.headers {
            headers[k] = v
        }
 
        var statusCode = self.serverResponse?.statusCode ?? 200
        if let length = length {
            headers["Content-Length"] = "\(length)"
        }
        
        if handler.hasRange {
            guard let totalLength = info.totalLength else {
               self.onReceiveAborted(handler.error("err.length.unknown"))
               return
            }
            
            let length = length ?? (totalLength - offset)
            if offset + length > totalLength {
                statusCode = 416
                headers["Content-Range"] = "bytes */\(totalLength)"
            } else {
                statusCode = 206
                headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(totalLength)"
            }
        }

        let response = NSHTTPURLResponse(URL: handler.request.URL!, statusCode: statusCode, HTTPVersion: "HTTP/1.1", headerFields: headers)!
        
        handler.client?.URLProtocol(handler, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
    }
    
    func onReceiveData(data: NSData) {
        if let handler = self.handler {
            handler.client?.URLProtocol(handler, didLoadData: data)
        }
    }
    
    func onReceiveFinished() {
        if let handler = self.handler {
            handler.client?.URLProtocolDidFinishLoading(handler)
        }
    }
    
    func onReceiveAborted(error: NSError?) {
        guard let handler = self.handler else {
            return
        }
        
        if let error = error {
            handler.client?.URLProtocol(handler, didFailWithError: error)
            return
        }
            
        if let serverResponse = self.serverResponse {
            var headers = [String: String]()
            for (key, value) in serverResponse.allHeaderFields {
                if let key = key as? String {
                    if let value = value as? NSNumber {
                        headers[key] = value.stringValue
                    } else if let value = value as? String {
                        headers[key] = value
                    }
                }
            }
            headers["Content-Length"] = "0"
            
            let response = NSHTTPURLResponse(URL: handler.request.URL!, statusCode: serverResponse.statusCode, HTTPVersion: "HTTP/1.1", headerFields: headers)!
            
            handler.client?.URLProtocol(handler, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
            handler.client?.URLProtocolDidFinishLoading(handler)
            return
        }
        
        handler.client?.URLProtocol(handler, didFailWithError: handler.error("err.cancelled"))
    }
}

