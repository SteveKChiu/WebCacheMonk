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
    private var session: URLSession!
    private var bridge: WebCacheFetcherBridge!

    public init(configuration: URLSessionConfiguration? = nil, trustSelfSignedServer: Bool = false) {
        self.bridge = WebCacheFetcherBridge(trustSelfSignedServer: trustSelfSignedServer)
        self.session = URLSession(configuration: configuration ?? URLSessionConfiguration.ephemeral(), delegate: self.bridge, delegateQueue: nil)
    }

    public func fetch(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default, progress: Progress? = nil, receiver: WebCacheReceiver) {
        var request = createFetchRequest(url, offset: offset, length: length, policy: policy)
        
        let r = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest;
        URLProtocol.setProperty("WebCacheFetcher", forKey: "WebCache", in: r)
        request = r as URLRequest;

        let task = self.session.dataTask(with: request)
        let info = WebCacheFetcherInfo(receiver: receiver, progress: progress)
        
        progress?.cancellationHandler = {
            [weak task] in
            task?.cancel()
        }
        
        task.fetcherInfo = info
        task.resume()
    }
    
    public func createFetchRequest(_ url: String, offset: Int64? = nil, length: Int64? = nil, policy: WebCachePolicy = .default) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
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
        
        return request
    }
}

//---------------------------------------------------------------------------

private var NSURLSessionTask_fetcherInfo = 0

private extension URLSessionTask {
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
    var progress: Progress?
    
    init(receiver: WebCacheReceiver, progress: Progress?) {
        self.receiver = receiver
        self.progress = progress
    }
}

//---------------------------------------------------------------------------

private class WebCacheFetcherBridge : NSObject, URLSessionDataDelegate {
    var trustSelfSignedServer: Bool

    init(trustSelfSignedServer: Bool) {
        self.trustSelfSignedServer = trustSelfSignedServer
    }

    func abortTask(_ task: URLSessionTask, error: NSError?) {
        if let info = task.fetcherInfo {
            info.receiver.onReceiveAborted(error)
            task.fetcherInfo = nil
        }
    }

    @objc func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: (URLSession.ResponseDisposition) -> Void) {
        guard let fetcher = dataTask.fetcherInfo else {
            completionHandler(.cancel)
            return
        }
        
        let receiver = fetcher.receiver
        receiver.onReceiveInited(response: response, progress: fetcher.progress)
        
        if fetcher.progress?.isCancelled == true {
            completionHandler(.cancel)
            abortTask(dataTask, error: nil)
            return
        }
        
        var offset: Int64 = 0
        var length: Int64? = response.expectedContentLength == -1 ? nil : response.expectedContentLength
        let info = WebCacheInfo(mimeType: response.mimeType)
        info.textEncoding = response.textEncodingName
        info.totalLength = length
        
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200, 204:
                break
                            
            case 206:
                if let range = http.allHeaderFields["Content-Range"] as? NSString {
                    let rex = try! RegularExpression(pattern: "bytes\\s+(\\d+)\\-(\\d+)/(\\d+)", options: [])
                    if let result = rex.matches(in: range as String, options: [], range: NSRange(0 ..< range.length)).first {
                        let n = result.numberOfRanges
                        if n >= 1 {
                            offset = Int64(range.substring(with: result.range(at: 1)))!
                        }
                        if n >= 2 {
                            let end = Int64(range.substring(with: result.range(at: 2)))!
                            length = end - offset + 1
                        }
                        if n >= 3 {
                            info.totalLength = Int64(range.substring(with: result.range(at: 3)))!
                        }
                    }
                }
                break
            
            case 404:
                completionHandler(.cancel)
                abortTask(dataTask, error: nil)
                return
            
            default:
                let error = NSError(domain: "WebCache.Fetcher", code: http.statusCode, userInfo: [
                    NSURLErrorKey: response.url!,
                    NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                ])
                completionHandler(.cancel)
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
        
        if fetcher.progress?.totalUnitCount < 0 {
            if offset + response.expectedContentLength == info.totalLength {
                fetcher.progress?.totalUnitCount = info.totalLength!
                fetcher.progress?.completedUnitCount = offset
            } else {
                fetcher.progress?.totalUnitCount = response.expectedContentLength
            }
        }

        receiver.onReceiveStarted(info, offset: offset, length: length)
        completionHandler(.allow)
    }

    @objc func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let info = dataTask.fetcherInfo {
            if info.progress?.isCancelled == true {
                abortTask(dataTask, error: nil)
            } else {
                info.receiver.onReceiveData(data)
                info.progress?.completedUnitCount += Int64(data.count)
            }
        }
    }
    
    @objc func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: NSError?) {
        if let info = task.fetcherInfo {
            if let error = error {
                info.receiver.onReceiveAborted(error)
            } else {
                info.receiver.onReceiveFinished()
            }
            task.fetcherInfo = nil
        }
    }

    @objc func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    @objc func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if self.trustSelfSignedServer && challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let credential = URLCredential(trust: challenge.protectionSpace.serverTrust!)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

