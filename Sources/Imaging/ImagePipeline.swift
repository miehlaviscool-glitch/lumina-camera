import CoreImage
import ImageIO
import UIKit
import Photos
import CoreLocation

enum ImagePipeline {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    static func scale(_ img: CIImage, maxSide: CGFloat) -> CIImage {
        let e = img.extent
        let m = max(e.width, e.height)
        var out = img
        if m > maxSide {
            out = img.lf("CILanczosScaleTransform", ["inputScale": maxSide / m, "inputAspectRatio": 1.0])
        }
        let oe = out.extent
        return out.transformed(by: CGAffineTransform(translationX: -oe.minX, y: -oe.minY))
    }

    static func crop(_ img: CIImage, to aspect: AspectRatio) -> CIImage {
        let e = img.extent
        let landscape = e.width >= e.height
        let ratio = aspect.longOverShort
        let target = landscape ? ratio : 1 / ratio       // width / height
        let current = e.width / e.height
        guard abs(current - target) > 0.002 else { return img }
        var r = e
        if current > target {
            r.size.width = (e.height * target).rounded(.down)
            r.origin.x = e.minX + ((e.width - r.size.width) / 2).rounded(.down)
        } else {
            r.size.height = (e.width / target).rounded(.down)
            r.origin.y = e.minY + ((e.height - r.size.height) / 2).rounded(.down)
        }
        let cropped = img.cropped(to: r)
        return cropped.transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    static func process(_ input: CIImage, filter: LuminaFilter?, intensity: Double,
                        adjustments: Adjustments, aspect: AspectRatio = .fourThree) -> CIImage {
        var img = input
        let extent = input.extent
        if let f = filter, !f.isIdentity {
            let filtered = f.transform(img).cropped(to: extent)
            if intensity < 0.995 {
                img = img.lf("CIDissolveTransition", ["inputTargetImage": filtered, "inputTime": intensity]).cropped(to: extent)
            } else {
                img = filtered
            }
        }
        if !adjustments.isIdentity { img = adjustments.apply(to: img) }
        return crop(img, to: aspect)
    }

    /// Mean luma (0...1, sRGB-encoded) of an image.
    static func averageLuma(_ img: CIImage) -> Double {
        let avg = img.lf("CIAreaAverage", ["inputExtent": CIVector(cgRect: img.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255
    }

    /// Exposure boost that lifts a dark night-sky stack toward a pleasing brightness.
    static func autoStretchEV(_ img: CIImage, target: Double = 0.22) -> Double {
        let m = max(averageLuma(scale(img, maxSide: 256)), 0.002)
        guard m < target else { return 0 }
        return min(3.0, max(0, 2.2 * log2(target / m)))
    }

    static func encode(_ image: CIImage, heif: Bool, metadata: [CFString: Any]? = nil, quality: Double = 0.93) -> Data? {
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: p3) else { return nil }
        let data = NSMutableData()
        let type = (heif ? "public.heic" : "public.jpeg") as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var props: [CFString: Any] = cleaned(metadata)
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func cleaned(_ meta: [CFString: Any]?) -> [CFString: Any] {
        guard var m = meta else { return [:] }
        m.removeValue(forKey: kCGImagePropertyOrientation)
        m.removeValue(forKey: kCGImagePropertyPixelWidth)
        m.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = m[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            m[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = m[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            m[kCGImagePropertyExifDictionary] = exif
        }
        return m
    }

    static func metadata(of data: Data) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return p
    }

    static func loadOriented(_ data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    static func processPhotoData(_ data: Data, filter: LuminaFilter?, intensity: Double,
                                 adjustments: Adjustments, aspect: AspectRatio, heif: Bool) -> Data? {
        guard let ci = loadOriented(data) else { return nil }
        let out = process(ci, filter: filter, intensity: intensity, adjustments: adjustments, aspect: aspect)
        return encode(out, heif: heif, metadata: metadata(of: data))
    }
}

enum PhotoSaver {
    static func savePhoto(_ data: Data, raw: Data? = nil, liveMovie: URL? = nil,
                          location: CLLocation? = nil, completion: ((Bool) -> Void)? = nil) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: PHAssetResourceCreationOptions())
            if let raw = raw {
                let o = PHAssetResourceCreationOptions()
                o.uniformTypeIdentifier = "com.adobe.raw-image"
                req.addResource(with: .alternatePhoto, data: raw, options: o)
            }
            if let m = liveMovie {
                let o = PHAssetResourceCreationOptions()
                o.shouldMoveFile = true
                req.addResource(with: .pairedVideo, fileURL: m, options: o)
            }
            req.location = location
        }, completionHandler: { ok, _ in DispatchQueue.main.async { completion?(ok) } })
    }

    static func saveVideo(_ url: URL, location: CLLocation? = nil, completion: ((Bool) -> Void)? = nil) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            let o = PHAssetResourceCreationOptions()
            o.shouldMoveFile = true
            req.addResource(with: .video, fileURL: url, options: o)
            req.location = location
        }, completionHandler: { ok, _ in DispatchQueue.main.async { completion?(ok) } })
    }

    static func latestThumbnail(size: CGFloat = 160, completion: @escaping (UIImage?) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { completion(nil); return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: opts).firstObject else { completion(nil); return }
        let ro = PHImageRequestOptions()
        ro.deliveryMode = .opportunistic
        ro.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size * 2, height: size * 2),
                                              contentMode: .aspectFill, options: ro) { img, _ in
            DispatchQueue.main.async { completion(img) }
        }
    }
}
