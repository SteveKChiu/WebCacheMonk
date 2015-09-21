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

private let DefaultCostLimit = 128 * 1024 * 1024

//---------------------------------------------------------------------------

public class WebImageCache : WebObjectCache<UIImage> {
    public static var shared = WebImageCache()

    public var decompressedCostLimit: Int = 512 * 512 * 4

    public init(name: String? = nil, configuration: NSURLSessionConfiguration? = nil) {
        super.init(name: name ?? "WebImageCache", configuration: configuration, decoder: nil)
        self.totalCostLimit = DefaultCostLimit
    }
    
    public init(path: String, configuration: NSURLSessionConfiguration? = nil) {
        super.init(path: path, configuration: configuration, decoder: nil)
        self.totalCostLimit = DefaultCostLimit
    }

    public init(source: WebCacheSource) {
        super.init(source: source, decoder: nil)
        self.totalCostLimit = DefaultCostLimit
    }
    
    public override func decode(data: NSData, options: [String: Any]?, completion: (UIImage?) -> Void) {
        if let decoder = self.decoder {
            decoder(data, options: options, completion: completion)
            return
        }
    
        guard let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        
        if evaluate(image) > self.decompressedCostLimit {
            completion(image)
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

            let image = self.decompress(image, scale: scale)
            completion(image)
        }
    }

    public override func evaluate(image: UIImage) -> Int {
        if let evaluator = self.evaluator {
            return evaluator(image)
        }
    
        let size = image.size
        return Int(size.width * size.height * 4)
    }

    private func decompress(image: UIImage, scale: CGFloat) -> UIImage? {
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
private var UIImageView_fetchCompleted = 0

public extension UIImageView {
    public private(set) var fetchProgress: NSProgress? {
        get {
            return objc_getAssociatedObject(self, &UIImageView_fetchProgress) as? NSProgress
        }
        set {
            objc_setAssociatedObject(self, &UIImageView_fetchProgress, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    public private(set) var fetchCompleted: Bool {
        get {
            let v = objc_getAssociatedObject(self, &UIImageView_fetchCompleted) as? NSNumber
            return v?.boolValue ?? false
        }
        set {
            objc_setAssociatedObject(self, &UIImageView_fetchCompleted, NSNumber(bool: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
        if url == self.imageURL && self.fetchCompleted {
            completion?()
            return
        }
    
        self.fetchProgress?.cancel()
        self.fetchProgress = nil
        
        objc_setAssociatedObject(self, &UIImageView_imageURL, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        guard let url = url else {
            self.image = placeholder
            self.fetchCompleted = true
            completion?()
            return
        }
        
        if let image = WebImageCache.shared.get(url.absoluteString, tag: tag) {
            self.image = image
            self.fetchCompleted = true
            completion?()
            return
        }
        
        self.fetchProgress = NSProgress(totalUnitCount: -1)
        self.fetchCompleted = false
        self.image = placeholder

        var tag = tag
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
                tag = nil
                break
            }
        }
        
        WebImageCache.shared.fetch(url.absoluteString, tag: tag, options: options, progress: self.fetchProgress) {
            image in

            dispatch_async(dispatch_get_main_queue()) {
                guard let image = image else {
                    completion?()
                    return
                }
                
                self.fetchProgress = nil
                self.fetchCompleted = true

                if animated {
                    UIView.transitionWithView(self, duration: 0.5, options: .TransitionCrossDissolve, animations: {
                        self.image = image
                    }, completion: {
                        _ in
                        completion?()
                    })
                } else {
                    self.image = image
                    completion?()
                }
            }
        }
    }
}
