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

public class WebImageCache : WebObjectCache<UIImage> {
    public static var shared = WebImageCache()

    public init(name: String? = nil, configuration: NSURLSessionConfiguration? = nil) {
        super.init(name: name ?? "WebImageCache", configuration: configuration, decoder: WebImageCache.decode)
        self.costEvaluator = WebImageCache.evaluate
        self.totalCostLimit = 128 * 1024 * 1024
    }
    
    public init(path: String, configuration: NSURLSessionConfiguration? = nil) {
        super.init(path: path, configuration: configuration, decoder: WebImageCache.decode)
        self.costEvaluator = WebImageCache.evaluate
        self.totalCostLimit = 128 * 1024 * 1024
    }

    public init(source: WebCacheSource) {
        super.init(source: source, decoder: WebImageCache.decode)
        self.costEvaluator = WebImageCache.evaluate
        self.totalCostLimit = 128 * 1024 * 1024
    }
    
    private static func decode(data: NSData, completion: (UIImage?) -> Void) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)) {
            completion(UIImage(data: data))
        }
    }

    private static func evaluate(image: UIImage) -> Int {
        let size = image.size
        return Int(size.width * size.height * 4)
    }
}

//---------------------------------------------------------------------------

private var UIImageView_imageURL = 0
private var UIImageView_fetchProgress = 0

public extension UIImageView {
    public var fetchProgress: NSProgress? {
        get {
            return objc_getAssociatedObject(self, &UIImageView_fetchProgress) as? NSProgress
        }
        set {
            objc_setAssociatedObject(self, &UIImageView_fetchProgress, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    public var imageURL: NSURL? {
        get {
            return objc_getAssociatedObject(self, &UIImageView_imageURL) as? NSURL
        }
        set {
            setImageWithURL(newValue)
        }
    }

    public func setImageWithURL(url: NSURL?, completion: (() -> Void)? = nil) {
        if url == self.imageURL && (completion == nil || self.fetchProgress == nil) {
            completion?()
            return
        }
    
        self.fetchProgress?.cancel()
        objc_setAssociatedObject(self, &UIImageView_imageURL, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        guard let url = url else {
            self.fetchProgress = nil
            self.image = nil
            completion?()
            return
        }
        
        self.fetchProgress = NSProgress(totalUnitCount: -1)
        WebImageCache.shared.fetch(url.absoluteString, progress: self.fetchProgress) {
            image in

            dispatch_async(dispatch_get_main_queue()) {
                self.fetchProgress = nil
                self.image = image
                completion?()
            }
        }
    }
}
