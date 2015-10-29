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

public class WebCacheFetcher : WebCacheSource {
    private var session: NSURLSession!
    private var bridge: WebCacheFetcherBridge!

    public init(configuration: NSURLSessionConfiguration? = nil) {
        self.bridge = WebCacheFetcherBridge(fetcher: self)
        self.session = NSURLSession(configuration: configuration ?? NSURLSessionConfiguration.ephemeralSessionConfiguration(), delegate: self.bridge, delegateQueue: nil)
    }

    public func fetch(url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .Default, progress: NSProgress? = nil, receiver: WebCacheReceiver) {
        let request = NSMutableURLRequest(URL: NSURL(string: url)!)
        request.HTTPMethod = "GET"
        request.setValue("gzip, identity", forHTTPHeaderField: "Accept-Encoding")
        
        if let offset = offset {
            if let length = length {
                request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
        } else if let length = length {
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        }
        
        NSURLProtocol.setProperty("WebCacheFetcher", forKey: "WebCache", inRequest: request)

        let task = self.session.dataTaskWithRequest(request)
        let info = WebCacheFetcherInfo(receiver: receiver, progress: progress)
        
        progress?.cancellationHandler = {
            [weak task] in
            
            task?.cancel()
        }
        
        task.fetcherInfo = info
        task.resume()
    }
}

//---------------------------------------------------------------------------

private var NSURLSessionTask_fetcherInfo = 0

private extension NSURLSessionTask {
    var fetcherInfo: WebCacheFetcherInfo? {
        get {
            return objc_getAssociatedObject(self, &NSURLSessionTask_fetcherInfo) as? WebCacheFetcherInfo
        }
        set {
            objc_setAssociatedObject(self, &NSURLSessionTask_fetcherInfo, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private class WebCacheFetcherInfo : NSObject {
    var receiver: WebCacheReceiver
    var progress: NSProgress?
    
    init(receiver: WebCacheReceiver, progress: NSProgress?) {
        self.receiver = receiver
        self.progress = progress
    }
}

//---------------------------------------------------------------------------

private class WebCacheFetcherBridge : NSObject, NSURLSessionDataDelegate {
    unowned var fetcher: WebCacheFetcher

    init(fetcher: WebCacheFetcher) {
        self.fetcher = fetcher
    }

    func abortTask(task: NSURLSessionTask, error: NSError?) {
        if let info = task.fetcherInfo {
            info.receiver.onReceiveAborted(error)
            task.fetcherInfo = nil
        }
    }

    @objc func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: (NSURLSessionResponseDisposition) -> Void) {
        guard let fetcher = dataTask.fetcherInfo else {
            completionHandler(.Cancel)
            return
        }
        
        let receiver = fetcher.receiver
        receiver.onReceiveInited(response: response, progress: fetcher.progress)
        
        if fetcher.progress?.cancelled == true {
            completionHandler(.Cancel)
            abortTask(dataTask, error: nil)
            return
        }
        
        if fetcher.progress?.totalUnitCount < 0 {
            fetcher.progress?.totalUnitCount = response.expectedContentLength
        }

        var offset: Int64 = 0
        var length: Int64? = response.expectedContentLength == -1 ? nil : response.expectedContentLength
        let info = WebCacheInfo(mimeType: response.MIMEType)
        info.textEncoding = response.textEncodingName
        info.totalLength = length
        
        if let http = response as? NSHTTPURLResponse {
            switch http.statusCode {
            case 200, 204:
                break
                            
            case 206:
                if let range = http.allHeaderFields["Content-Range"] as? NSString {
                    let rex = try! NSRegularExpression(pattern: "bytes\\s+(\\d+)\\-(\\d+)/(\\d+)", options: [])
                    if let result = rex.matchesInString(range as String, options: [], range: NSRange(0 ..< range.length)).first {
                        let n = result.numberOfRanges
                        if n >= 1 {
                            offset = Int64(range.substringWithRange(result.rangeAtIndex(1)))!
                        }
                        if n >= 2 {
                            let end = Int64(range.substringWithRange(result.rangeAtIndex(2)))!
                            length = end - offset + 1
                        }
                        if n >= 3 {
                            info.totalLength = Int64(range.substringWithRange(result.rangeAtIndex(3)))!
                        }
                    }
                }
                break
            
            case 404:
                completionHandler(.Cancel)
                abortTask(dataTask, error: nil)
                return
            
            default:
                let error = NSError(domain: "WebCache.Fetcher", code: http.statusCode, userInfo: [
                    NSURLErrorKey: response.URL!,
                    NSLocalizedDescriptionKey: NSHTTPURLResponse.localizedStringForStatusCode(http.statusCode)
                ])
                completionHandler(.Cancel)
                abortTask(dataTask, error: error)
                return
            }
            
            for (key, value) in http.allHeaderFields {
                if let key = key as? String where WebCacheInfo.HeaderKeys.contains(key) {
                    if let value = value as? String {
                        info.headers[key] = value
                    } else if let value = value as? NSNumber {
                        info.headers[key] = value.stringValue
                    }
                }
            }
        }
        
        receiver.onReceiveStarted(info, offset: offset, length: length)
        completionHandler(.Allow)
    }

    @objc func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
        if let info = dataTask.fetcherInfo {
            if info.progress?.cancelled == true {
                abortTask(dataTask, error: nil)
            } else {
                info.receiver.onReceiveData(data)
                info.progress?.completedUnitCount += Int64(data.length)
            }
        }
    }
    
    @objc func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
        if let info = task.fetcherInfo {
            if let error = error {
                info.receiver.onReceiveAborted(error)
            } else {
                info.receiver.onReceiveFinished()
            }
            task.fetcherInfo = nil
        }
    }

    @objc func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, willCacheResponse proposedResponse: NSCachedURLResponse, completionHandler: (NSCachedURLResponse?) -> Void) {
        completionHandler(nil)
    }
}

