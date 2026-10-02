import CoreImage
import UIKit

extension CIImage {
    /// Applies a Core Image filter by name, returning self if the filter is unavailable.
    func lf(_ name: String, _ params: [String: Any] = [:]) -> CIImage {
        var p = params
        p[kCIInputImageKey] = self
        return CIFilter(name: name, parameters: p)?.outputImage ?? self
    }
}

struct LuminaFilter: Identifiable, Equatable {
    let id: String
    let name: String
    let transform: (CIImage) -> CIImage

    var isIdentity: Bool { id == "original" }
    static func == (a: LuminaFilter, b: LuminaFilter) -> Bool { a.id == b.id }

    static let original = LuminaFilter(id: "original", name: "Original") { $0 }

    private static func matrix(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        img.lf("CIColorMatrix", [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    static let all: [LuminaFilter] = [
        original,
        LuminaFilter(id: "vivid", name: "Vivid") { $0.lf("CIVibrance", ["inputAmount": 0.8]).lf("CIColorControls", ["inputSaturation": 1.15, "inputContrast": 1.08]) },
        LuminaFilter(id: "chrome", name: "Chrome") { $0.lf("CIPhotoEffectChrome") },
        LuminaFilter(id: "fade", name: "Fade") { $0.lf("CIPhotoEffectFade") },
        LuminaFilter(id: "instant", name: "Instant") { $0.lf("CIPhotoEffectInstant") },
        LuminaFilter(id: "process", name: "Process") { $0.lf("CIPhotoEffectProcess") },
        LuminaFilter(id: "transfer", name: "Transfer") { $0.lf("CIPhotoEffectTransfer") },
        LuminaFilter(id: "tealorange", name: "Cinema") { img in
            let e = img.extent
            let base = img.lf("CIColorControls", ["inputContrast": 1.12, "inputSaturation": 1.1])
            guard let g = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: e.maxY), "inputPoint1": CIVector(x: 0, y: e.minY),
                "inputColor0": CIColor(red: 0.0, green: 0.45, blue: 0.6),
                "inputColor1": CIColor(red: 1.0, green: 0.55, blue: 0.2)])?.outputImage?.cropped(to: e) else { return base }
            return g.lf("CISoftLightBlendMode", [kCIInputBackgroundImageKey: base])
        },
        LuminaFilter(id: "golden", name: "Golden") { img in
            matrix(img, r: 1.1, g: 1.0, b: 0.84).lf("CIVibrance", ["inputAmount": 0.4]).lf("CIColorControls", ["inputContrast": 1.05])
        },
        LuminaFilter(id: "cool", name: "Cool") { matrix($0, r: 0.9, g: 1.0, b: 1.12) },
        LuminaFilter(id: "matte", name: "Matte") {
            $0.lf("CIColorControls", ["inputContrast": 0.9, "inputSaturation": 0.85])
                .lf("CIColorClamp", ["inputMinComponents": CIVector(x: 0.06, y: 0.06, z: 0.06, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        },
        LuminaFilter(id: "vintage", name: "Vintage") {
            $0.lf("CISepiaTone", ["inputIntensity": 0.45])
                .lf("CIColorControls", ["inputContrast": 0.95, "inputSaturation": 0.9])
                .lf("CIVignette", ["inputIntensity": 0.9, "inputRadius": 1.6])
        },
        LuminaFilter(id: "sepia", name: "Sepia") { $0.lf("CISepiaTone", ["inputIntensity": 0.9]) },
        LuminaFilter(id: "mono", name: "Mono") { $0.lf("CIPhotoEffectMono") },
        LuminaFilter(id: "tonal", name: "Tonal") { $0.lf("CIPhotoEffectTonal") },
        LuminaFilter(id: "noir", name: "Noir") { $0.lf("CIPhotoEffectNoir") },
        LuminaFilter(id: "silver", name: "Silver") {
            $0.lf("CIColorControls", ["inputSaturation": 0, "inputContrast": 1.35, "inputBrightness": 0.02])
                .lf("CIVignette", ["inputIntensity": 0.6, "inputRadius": 1.8])
        },
        LuminaFilter(id: "cyber", name: "Cyber") {
            $0.lf("CIHueAdjust", ["inputAngle": 0.35]).lf("CIVibrance", ["inputAmount": 1.0])
                .lf("CIColorControls", ["inputContrast": 1.2, "inputSaturation": 1.3])
        },
        LuminaFilter(id: "dream", name: "Dream") { img in
            let e = img.extent
            return img.lf("CIBloom", ["inputRadius": 12.0, "inputIntensity": 0.9]).cropped(to: e)
                .lf("CIColorControls", ["inputBrightness": 0.03, "inputSaturation": 1.1])
        },
        LuminaFilter(id: "glow", name: "Glow") { img in
            let e = img.extent
            return img.lf("CIGloom", ["inputRadius": 8.0, "inputIntensity": 0.4]).cropped(to: e)
        },
        LuminaFilter(id: "comic", name: "Comic") { $0.lf("CIComicEffect") },
        LuminaFilter(id: "astro", name: "Astro") {
            $0.lf("CIHighlightShadowAdjust", ["inputShadowAmount": 0.6, "inputHighlightAmount": 0.9])
                .lf("CIColorControls", ["inputContrast": 1.2, "inputSaturation": 1.25])
        }
    ]
}

struct Adjustments: Equatable {
    var exposure = 0.0      // EV
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var vibrance = 0.0
    var warmth = 0.0        // -1...1
    var tint = 0.0          // -1...1
    var highlights = 1.0    // 0...1 (1 = untouched)
    var shadows = 0.0       // -1...1
    var sharpness = 0.0
    var vignette = 0.0
    var grain = 0.0

    var isIdentity: Bool { self == Adjustments() }

    func apply(to input: CIImage) -> CIImage {
        let e = input.extent
        var img = input
        if exposure != 0 { img = img.lf("CIExposureAdjust", ["inputEV": exposure]) }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            img = img.lf("CIColorControls", ["inputBrightness": brightness, "inputContrast": contrast, "inputSaturation": saturation])
        }
        if vibrance != 0 { img = img.lf("CIVibrance", ["inputAmount": vibrance]) }
        if warmth != 0 || tint != 0 {
            img = img.lf("CIColorMatrix", [
                "inputRVector": CIVector(x: 1 + 0.18 * warmth, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - 0.12 * tint, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.18 * warmth, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        if highlights != 1 || shadows != 0 {
            img = img.lf("CIHighlightShadowAdjust", ["inputHighlightAmount": highlights, "inputShadowAmount": shadows])
        }
        if sharpness > 0 { img = img.lf("CISharpenLuminance", ["inputSharpness": sharpness]) }
        if vignette > 0 { img = img.lf("CIVignette", ["inputIntensity": vignette, "inputRadius": 1.5]) }
        if grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: e) {
            let mono = noise.lf("CIColorControls", ["inputSaturation": 0])
            let blended = mono.lf("CISoftLightBlendMode", [kCIInputBackgroundImageKey: img])
            img = img.lf("CIDissolveTransition", ["inputTargetImage": blended, "inputTime": grain * 0.6])
        }
        return img.cropped(to: e)
    }
}
