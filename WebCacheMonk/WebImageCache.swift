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

open class WebImageCache : WebObjectCache<UIImage> {
    open static var shared = WebImageCache()

    open var decompressedCostLimit: Int = 512 * 512 * 4

    public init(name: String? = nil, configuration: URLSessionConfiguration? = nil) {
        super.init(name: name ?? "WebImageCache", configuration: configuration, decoder: nil)
        self.totalCostLimit = DefaultCostLimit
    }
    
    public init(path: String, configuration: URLSessionConfiguration? = nil) {
        super.init(path: path, configuration: configuration, decoder: nil)
        self.totalCostLimit = DefaultCostLimit
    }

    public init(source: WebCacheSource) {
        super.init(source: source, decoder: nil)
        self.totalCostLimit = DefaultCostLimit
    }
    
    open override func decode(_ data: Data, options: [String: Any]?, completion: @escaping (UIImage?) -> Void) {
        if let decoder = self.decoder {
            decoder(data, options, completion)
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
        
        DispatchQueue.global(qos: DispatchQoS.QoSClass.utility).async {
            var scale: CGFloat = 1
            
            if let options = options,
                   let width = options["width"] as? CGFloat,
                   let height = options["height"] as? CGFloat {
                let mode = (options["mode"] as? UIViewContentMode) ?? UIViewContentMode.scaleToFill
                let widthScale = min(width / image.size.width, 1)
                let heightScale = min(height / image.size.width, 1)
                
                switch mode {
                case .scaleToFill, .scaleAspectFill:
                    scale = max(widthScale, heightScale)
                    
                case .scaleAspectFit:
                    scale = min(widthScale, heightScale)
                    
                default:
                    break
                }
            }

            let image = self.decompress(image, scale: scale)
            completion(image)
        }
    }

    open override func evaluate(_ image: UIImage) -> Int {
        if let evaluator = self.evaluator {
            return evaluator(image)
        }
    
        let size = image.size
        return Int(size.width * size.height * 4)
    }

    private func decompress(_ image: UIImage, scale: CGFloat) -> UIImage? {
        guard let imageRef = image.cgImage else {
            return image
        }
        
        var bitmapInfo = imageRef.bitmapInfo.rawValue
        let alphaInfo = imageRef.alphaInfo
        
        switch (alphaInfo) {
        case .none:
            bitmapInfo &= ~CGBitmapInfo.alphaInfoMask.rawValue
            bitmapInfo |= CGImageAlphaInfo.noneSkipFirst.rawValue
        case .premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast:
            break
        case .alphaOnly, .last, .first:
            return image
        }
        
        let screenScale = UIScreen.main.scale
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixelScale = min(scale * screenScale, image.scale)
        let pixelSize = CGSize(width: image.size.width * pixelScale, height: image.size.height * pixelScale)
        
        guard let context = CGContext(data: nil, width: Int(ceil(pixelSize.width)), height: Int(ceil(pixelSize.height)), bitsPerComponent: imageRef.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return image
        }
            
        let imageRect = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        UIGraphicsPushContext(context)
        
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1.0, y: -1.0)
        
        image.draw(in: imageRect)
        UIGraphicsPopContext()
        
        guard let decompressedImageRef = context.makeImage() else {
            return image
        }
        
        return UIImage(cgImage: decompressedImageRef, scale: screenScale, orientation: .up)
    }
}

//---------------------------------------------------------------------------

private var UIImageView_imageURL = 0
private var UIImageView_fetchProgress = 0
private var UIImageView_fetchCompleted = 0

public extension UIImageView {
    public private(set) var fetchProgress: Progress? {
        get {
            return objc_getAssociatedObject(self, &UIImageView_fetchProgress) as? Progress
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
            objc_setAssociatedObject(self, &UIImageView_fetchCompleted, NSNumber(value: newValue as Bool), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    public var imageURL: URL? {
        get {
            return objc_getAssociatedObject(self, &UIImageView_imageURL) as? URL
        }
        set {
            setImageWithURL(newValue, animated: false)
        }
    }

    public func setImageWithURL(_ url: URL?, placeholder: UIImage? = nil, tag: String? = nil, animated: Bool, completion: (() -> Void)? = nil) {
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
        
        self.fetchProgress = Progress(totalUnitCount: -1)
        self.fetchCompleted = false
        self.image = placeholder

        var tag = tag
        var options: [String: Any]?
        if tag != nil {
            switch self.contentMode {
            case .scaleToFill, .scaleAspectFill, .scaleAspectFit:
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

            DispatchQueue.main.async {
                guard let image = image else {
                    completion?()
                    return
                }
                
                self.fetchProgress = nil
                self.fetchCompleted = true

                if animated {
                    UIView.transition(with: self, duration: 0.5, options: .transitionCrossDissolve, animations: {
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
