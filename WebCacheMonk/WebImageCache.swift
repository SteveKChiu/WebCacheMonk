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

private let DEFAULT_COST_LIMIT = 128 * 1024 * 1024

//---------------------------------------------------------------------------

public class WebImageCache : WebObjectCache<UIImage> {
    public static var shared = WebImageCache()

    public init(name: String? = nil, configuration: NSURLSessionConfiguration? = nil) {
        super.init(name: name ?? "WebImageCache", configuration: configuration, decoder: WebImageCache.decode)
        self.costEvaluator = WebImageCache.evaluate
        self.totalCostLimit = DEFAULT_COST_LIMIT
    }
    
    public init(path: String, configuration: NSURLSessionConfiguration? = nil) {
        super.init(path: path, configuration: configuration, decoder: WebImageCache.decode)
        self.costEvaluator = WebImageCache.evaluate
        self.totalCostLimit = DEFAULT_COST_LIMIT
    }

    public init(source: WebCacheSource) {
        super.init(source: source, decoder: WebImageCache.decode)
        self.costEvaluator = WebImageCache.evaluate
        self.totalCostLimit = DEFAULT_COST_LIMIT
    }
    
    private static func decode(data: NSData, options: [String: Any]?, completion: (UIImage?) -> Void) {
        guard let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)) {
            var scale: CGFloat = 1
            
            if let options = options,
                   width = options["width"] as? CGFloat,
                   height = options["height"] as? CGFloat {
                let mode = (options["mode"] as? UIViewContentMode) ?? UIViewContentMode.ScaleToFill
                let widthScale = min(width / image.size.width, 1)
                let heightScale = min(height / image.size.width, 1)
                
                switch mode {
                case .ScaleToFill, .ScaleAspectFill:
                    scale = max(widthScale, heightScale)
                    
                case .ScaleAspectFit:
                    scale = min(widthScale, heightScale)
                    
                default:
                    break
                }
            }

            let image = decompressedImage(image, scale: scale)
            completion(image)
        }
    }

    private static func evaluate(image: UIImage) -> Int {
        let size = image.size
        return Int(size.width * size.height * 4)
    }

    private static func decompressedImage(image: UIImage, scale: CGFloat) -> UIImage? {
        let imageRef = image.CGImage
        var bitmapInfo = CGImageGetBitmapInfo(imageRef).rawValue
        let alphaInfo = CGImageGetAlphaInfo(imageRef)
        
        switch (alphaInfo) {
        case .None:
            bitmapInfo &= ~CGBitmapInfo.AlphaInfoMask.rawValue
            bitmapInfo |= CGImageAlphaInfo.NoneSkipFirst.rawValue
        case .PremultipliedFirst, .PremultipliedLast, .NoneSkipFirst, .NoneSkipLast:
            break
        case .Only, .Last, .First:
            return image
        }
        
        let screenScale = UIScreen.mainScreen().scale
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixelScale = min(scale * screenScale, image.scale)
        let pixelSize = CGSizeMake(image.size.width * pixelScale, image.size.height * pixelScale)
        
        guard let context = CGBitmapContextCreate(nil, Int(ceil(pixelSize.width)), Int(ceil(pixelSize.height)), CGImageGetBitsPerComponent(imageRef), 0, colorSpace, bitmapInfo) else {
            return image
        }
            
        let imageRect = CGRectMake(0, 0, pixelSize.width, pixelSize.height)
        UIGraphicsPushContext(context)
        
        CGContextTranslateCTM(context, 0, pixelSize.height)
        CGContextScaleCTM(context, 1.0, -1.0)
        
        image.drawInRect(imageRect)
        UIGraphicsPopContext()
        
        guard let decompressedImageRef = CGBitmapContextCreateImage(context) else {
            return image
        }
        
        return UIImage(CGImage: decompressedImageRef, scale: screenScale, orientation: .Up)
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
            setImageWithURL(newValue, animated: false)
        }
    }

    public func setImageWithURL(url: NSURL?, placeholder: UIImage? = nil, tag: String? = nil, animated: Bool, completion: (() -> Void)? = nil) {
        if url == self.imageURL && (completion == nil || self.fetchProgress == nil) {
            completion?()
            return
        }
    
        self.fetchProgress?.cancel()
        objc_setAssociatedObject(self, &UIImageView_imageURL, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        guard let url = url else {
            self.fetchProgress = nil
            self.image = placeholder
            completion?()
            return
        }
        
        self.fetchProgress = NSProgress(totalUnitCount: -1)
        self.image = placeholder
        
        var options: [String: Any]?
        if tag != nil {
            switch self.contentMode {
            case .ScaleToFill, .ScaleAspectFill, .ScaleAspectFit:
                options = [
                    "width": self.bounds.width,
                    "height": self.bounds.height,
                    "mode": self.contentMode,
                ]
                
            default:
                break
            }
        }
        
        WebImageCache.shared.fetch(url.absoluteString, tag: options != nil ? tag : nil, options: options, progress: self.fetchProgress) {
            image in

            dispatch_async(dispatch_get_main_queue()) {
                self.fetchProgress = nil
                if animated {
                    UIView.transitionWithView(self, duration: 0.15, options: .TransitionCrossDissolve, animations: {
                        self.image = image
                    }, completion: nil)
                } else {
                    self.image = image
                }
                completion?()
            }
        }
    }
}
