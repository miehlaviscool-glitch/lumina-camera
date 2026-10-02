import SwiftUI
import AVFoundation

enum StackBlend { case average, lighten }

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo, portrait, night, stars, trails, longExposure, pro, macro, video, slowMo, timelapse, scan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "PHOTO"
        case .portrait: return "PORTRAIT"
        case .night: return "NIGHT"
        case .stars: return "STARS"
        case .trails: return "TRAILS"
        case .longExposure: return "LONG EXP"
        case .pro: return "PRO"
        case .macro: return "MACRO"
        case .video: return "VIDEO"
        case .slowMo: return "SLO-MO"
        case .timelapse: return "TIME-LAPSE"
        case .scan: return "SCAN"
        }
    }

    var blurb: String {
        switch self {
        case .photo: return "Smart photo: HEIF, Live Photo, flash"
        case .portrait: return "Depth portrait. Adjust blur later in Photos"
        case .night: return "Hold steady. Aligns and merges frames for clean low light"
        case .stars: return "Astro preset: infinity focus, long exposure, high ISO, stacked. Use a tripod"
        case .trails: return "Stacks frames into star trails. Tripod required"
        case .longExposure: return "Silky water, clouds and light trails. Tripod recommended"
        case .pro: return "Manual ISO, shutter, focus and white balance. RAW"
        case .macro: return "Close-up focus on the ultra wide lens"
        case .video: return "Video with resolution and frame rate control"
        case .slowMo: return "High frame rate slow motion"
        case .timelapse: return "Builds a time-lapse video from interval frames"
        case .scan: return "Scans QR codes and barcodes"
        }
    }

    var icon: String {
        switch self {
        case .photo: return "camera"
        case .portrait: return "person.crop.circle"
        case .night: return "moon.stars"
        case .stars: return "sparkles"
        case .trails: return "scribble.variable"
        case .longExposure: return "drop"
        case .pro: return "slider.horizontal.3"
        case .macro: return "leaf"
        case .video: return "video"
        case .slowMo: return "tortoise"
        case .timelapse: return "timelapse"
        case .scan: return "qrcode.viewfinder"
        }
    }

    var isVideo: Bool { self == .video || self == .slowMo }
    var isStack: Bool { [.night, .stars, .trails, .longExposure].contains(self) }
    var isStill: Bool { [.photo, .portrait, .pro, .macro].contains(self) }
    var usesAspect: Bool { isStill || isStack }
    var alignsFrames: Bool { self == .night }

    var stackDurations: [Int] {
        switch self {
        case .night: return [3, 6, 10]
        case .stars: return [10, 20, 30, 60]
        case .trails: return [30, 60, 120, 300]
        case .longExposure: return [2, 4, 8, 15]
        default: return []
        }
    }
}

enum FlashSetting: String {
    case off, auto, on
    var next: FlashSetting { self == .off ? .auto : (self == .auto ? .on : .off) }
    var icon: String { self == .off ? "bolt.slash.fill" : (self == .auto ? "bolt.badge.automatic.fill" : "bolt.fill") }
    var avMode: AVCaptureDevice.FlashMode { self == .off ? .off : (self == .auto ? .auto : .on) }
}

enum AspectRatio: String, CaseIterable {
    case fourThree = "4:3", sixteenNine = "16:9", square = "1:1"
    var next: AspectRatio {
        let all = AspectRatio.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
    /// long side / short side
    var longOverShort: CGFloat {
        switch self {
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .square: return 1
        }
    }
}

enum GridStyle: String, CaseIterable {
    case off, thirds, golden, diagonal
    var next: GridStyle {
        let all = GridStyle.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum ProTab: String, CaseIterable, Identifiable {
    case ev = "EV", iso = "ISO", shutter = "SS", focus = "FOCUS", wb = "WB"
    var id: String { rawValue }
}

extension UIDeviceOrientation {
    var avOrientation: AVCaptureVideoOrientation {
        switch self {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
    /// Rotation to apply to an upright-portrait frame so it matches how the phone is held.
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .landscapeLeft: return .right
        case .landscapeRight: return .left
        case .portraitUpsideDown: return .down
        default: return .up
        }
    }
}

enum Keys {
    static let heif = "heif", keepOriginal = "keepOriginal", geotag = "geotag", grid = "grid"
    static let level = "level", histogram = "histogram", peaking = "peaking", raw = "raw"
    static let highRes = "highRes", live = "live", nightUI = "nightUI"
    static let videoRes = "videoRes", videoFPS = "videoFPS", mirrorFront = "mirrorFront"
    static let haptics = "haptics", timelapseInterval = "tlInterval"
}

enum AppDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            Keys.heif: true, Keys.keepOriginal: false, Keys.geotag: false, Keys.grid: GridStyle.thirds.rawValue,
            Keys.level: true, Keys.histogram: false, Keys.peaking: false, Keys.raw: false,
            Keys.highRes: false, Keys.live: false, Keys.nightUI: false,
            Keys.videoRes: 1920, Keys.videoFPS: 30, Keys.mirrorFront: true,
            Keys.haptics: true, Keys.timelapseInterval: 2
        ])
    }
}

extension UserDefaults {
    func flag(_ key: String) -> Bool { bool(forKey: key) }
}
