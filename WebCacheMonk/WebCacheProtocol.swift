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

open class WebCacheProtocol : URLProtocol {
    open override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: "WebCache", in: request) == nil else {
            return false
        }
        
        return prepareToFetch(request) != nil
    }
    
    open override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    open class func prepareToFetch(_ request: URLRequest) -> (URL, WebCacheSource)? {
        // subclass should override this
        return nil
    }

    private var progress: Progress?
    fileprivate var hasRange = false
    
    open var cacheControlMaxAge: TimeInterval {
        return  24 * 60 * 60
    }
    
    open override func startLoading() {
        guard let client = self.client else {
            return
        }
        
        guard let (url, dataSource) = type(of: self).prepareToFetch(self.request) else {
            client.urlProtocol(self, didFailWithError: WebCacheError("WebCacheMonk.InvalidURL", url: self.request.url?.absoluteString))
            return
        }
        
        self.progress = Progress(totalUnitCount: -1)
        self.hasRange = false
        
        var offset: Int64?
        var length: Int64?
        
        if let range = self.request.value(forHTTPHeaderField: "Range") {
            self.hasRange = true
            let range = range as NSString
            let rex = try! NSRegularExpression(pattern: "bytes\\s*=\\s*(\\d+)\\-(\\d*)", options: [])
            
            if let result = rex.matches(in: range as String, options: [], range: NSRange(0 ..< range.length)).first {
                let n = result.numberOfRanges
                if n >= 1 {
                    offset = Int64(range.substring(with: result.rangeAt(1)))!
                }
                if n >= 2 {
                    let end = Int64(range.substring(with: result.rangeAt(2)))!
                    length = end - (offset ?? 0) + 1
                }
            }
        }
        
        dataSource.fetch(url.absoluteString, offset: offset, length: length, policy: .default, progress: self.progress, receiver: WebCacheProtocolReceiver(self))
    }
     
    open override func stopLoading() {
        self.progress?.cancel()
        self.progress = nil
    }
}

//---------------------------------------------------------------------------

private class WebCacheProtocolReceiver : WebCacheReceiver {
    weak var handler: WebCacheProtocol?
    var serverResponse: HTTPURLResponse?
    var progress: Progress?

    init(_ handler: WebCacheProtocol) {
        self.handler = handler
    }

    func onReceiveInited(response: URLResponse?, progress: Progress?) {
        self.serverResponse = response as? HTTPURLResponse
        self.progress = progress
    }
    
    func onReceiveStarted(_ info: WebCacheInfo, offset: Int64, length: Int64?) {
        guard let handler = self.handler else {
            return
        }
    
        var contentType = info.mimeType
        if let textEncoding = info.textEncoding {
            contentType += "; charset=" + textEncoding
        }
    
        let maxAge = Int(handler.cacheControlMaxAge)
        var headers = [String: String]()
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Accept-Ranges"] = "bytes"
        headers["Cache-Control"] = "max-age=\(maxAge)"
        headers["Content-Type"] = contentType
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
               self.onReceiveAborted(WebCacheError("WebCacheMonk.UnknownLength", url: handler.request.url?.absoluteString))
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

        let response = HTTPURLResponse(url: handler.request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        
        handler.client?.urlProtocol(handler, didReceive: response, cacheStoragePolicy: maxAge == 0 ? .notAllowed : .allowedInMemoryOnly)
    }
    
    func onReceiveData(_ data: Data) {
        if let handler = self.handler {
            handler.client?.urlProtocol(handler, didLoad: data)
        }
    }
    
    func onReceiveFinished() {
        if let handler = self.handler {
            handler.client?.urlProtocolDidFinishLoading(handler)
        }
    }
    
    func onReceiveAborted(_ error: Error?) {
        guard let handler = self.handler else {
            return
        }
        
        if let error = error {
            handler.client?.urlProtocol(handler, didFailWithError: error)
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
            
            let response = HTTPURLResponse(url: handler.request.url!, statusCode: serverResponse.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
            
            handler.client?.urlProtocol(handler, didReceive: response, cacheStoragePolicy: .notAllowed)
            handler.client?.urlProtocolDidFinishLoading(handler)
            return
        }
        
        handler.client?.urlProtocol(handler, didFailWithError: WebCacheError("WebCacheMonk.Cancalled", url: handler.request.url?.absoluteString))
    }
}

