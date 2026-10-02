import AVFoundation
import Photos
import UIKit
import CoreLocation
import CoreMotion

private struct ConfigSnapshot {
    var mode: CaptureMode
    var position: AVCaptureDevice.Position
    var raw: Bool
    var highRes: Bool
    var live: Bool
    var videoWidth: Int32
    var fps: Double
    var mirror: Bool
}

struct CaptureSnapshot {
    var mode: CaptureMode
    var flash: FlashSetting
    var raw: Bool
    var live: Bool
    var heif: Bool
    var keepOriginal: Bool
    var aspect: AspectRatio
    var filter: LuminaFilter
    var intensity: Double
    var orientation: UIDeviceOrientation
    var location: CLLocation?
    var needsProcessing: Bool {
        (!filter.isIdentity) || aspect != .fourThree
    }
}

final class CameraManager: NSObject, ObservableObject {
    // MARK: Published state
    @Published var mode: CaptureMode = .photo
    @Published var position: AVCaptureDevice.Position = .back
    @Published var permissionDenied = false
    @Published var running = false

    @Published var zoomDisplay: CGFloat = 1
    @Published var lensButtons: [CGFloat] = [1]
    @Published var minZoom: CGFloat = 1
    @Published var maxZoom: CGFloat = 10

    @Published var flash: FlashSetting = .off
    @Published var torchOn = false
    @Published var timer = 0
    @Published var aspect: AspectRatio = .fourThree
    @Published var countdown: Int?
    @Published var captureFlash = false

    @Published var filter: LuminaFilter = .original
    @Published var filterIntensity = 1.0

    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var isStacking = false
    @Published var stackProgress = 0.0
    @Published var stackFrames = 0
    @Published var isTimelapse = false
    @Published var timelapseFrames = 0
    @Published var stackDuration = 20
    @Published var stackBlend: StackBlend = .average
    @Published var burstActive = false

    @Published var manualExposure = false
    @Published var manualFocus = false
    @Published var manualWB = false
    @Published var shutterT = 0.4
    @Published var isoT = 0.3
    @Published var focusT = 0.5
    @Published var kelvin = 5500.0
    @Published var evBias: Float = 0
    @Published var proTab: ProTab = .iso
    @Published var liveISO: Float = 0
    @Published var liveShutter = 0.0
    @Published var shutterRange: ClosedRange<Double> = 0.0001...1
    @Published var isoRange: ClosedRange<Float> = 25...3200

    @Published var hasFlash = false
    @Published var hasTorch = false
    @Published var supportsRAW = false
    @Published var supportsLive = false
    @Published var supports48 = false
    @Published var supportsDepth = false

    @Published var histogram: [Float] = []
    @Published var previewImage: CGImage?
    @Published var sampleImage: CGImage?
    @Published var scannedCode: String?
    @Published var toast: String?
    @Published var thumbnail: UIImage?
    @Published var rollAngle: Double = 0
    @Published var wantsFilterSamples = false {
        didSet { updateFrameConfig() }
    }

    // MARK: Internals
    let session = AVCaptureSession()
    let frames = FrameProcessor()
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let queue = DispatchQueue(label: "lumina.session")
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let dataOutput = AVCaptureVideoDataOutput()
    private let metaOutput = AVCaptureMetadataOutput()
    private var zoomBase: CGFloat = 1
    private var inFlight: [Int64: PhotoDelegate] = [:]
    private var stackOrientation: UIDeviceOrientation = .portrait
    private var stackSnapshot: CaptureSnapshot?
    private var recordTimer: Timer?
    private var burstTimer: Timer?
    private var liveTimer: Timer?
    private var qrClear: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private let motion = CMMotionManager()
    private let location = LocationProvider()
    private var started = false

    private var defaults: UserDefaults { .standard }

    override init() {
        super.init()
        frames.onPreview = { [weak self] in self?.previewImage = $0 }
        frames.onHistogram = { [weak self] in self?.histogram = $0 }
        frames.onSample = { [weak self] in self?.sampleImage = $0 }
        frames.onStackProgress = { [weak self] p, n in self?.stackProgress = p; self?.stackFrames = n }
        frames.onStackFinished = { [weak self] image, n in self?.stackFinished(image, count: n) }
        frames.onTimelapseFrames = { [weak self] in self?.timelapseFrames = $0 }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Lifecycle

    func start() {
        if started { resume(); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.begin() : (self.permissionDenied = true) }
            }
        default: permissionDenied = true
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in self?.refreshThumbnail() }
        if defaults.flag(Keys.geotag) { location.start() }
        startMotion()
    }

    private func begin() {
        started = true
        permissionDenied = false
        let snap = snapshotConfig()
        queue.async {
            self.configure(snap)
            self.session.startRunning()
            DispatchQueue.main.async { self.running = true }
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollDevice() }
        updateFrameConfig()
    }

    func resume() {
        guard started else { return }
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.running = true }
        }
    }

    func pause() {
        guard started else { return }
        if isRecording { toggleRecording() }
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        running = false
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            let upright = abs(g.z) < 0.75
            self?.rollAngle = upright ? atan2(g.x, -g.y) : .nan
        }
    }

    private func pollDevice() {
        guard let d = device else { return }
        liveISO = d.iso
        liveShutter = d.exposureDuration.seconds
    }

    // MARK: - Configuration

    private func snapshotConfig() -> ConfigSnapshot {
        ConfigSnapshot(mode: mode, position: position, raw: defaults.flag(Keys.raw), highRes: defaults.flag(Keys.highRes),
                       live: defaults.flag(Keys.live), videoWidth: Int32(defaults.integer(forKey: Keys.videoRes)),
                       fps: Double(defaults.integer(forKey: Keys.videoFPS)), mirror: defaults.flag(Keys.mirrorFront))
    }

    /// Re-applies session configuration (after a mode, camera or settings change).
    func reconfigure() {
        guard started else { return }
        let snap = snapshotConfig()
        queue.async {
            self.configure(snap)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func discover(_ s: ConfigSnapshot) -> AVCaptureDevice? {
        if s.position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        if s.mode == .macro, let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) { return uw }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        for t in types {
            if let d = AVCaptureDevice.default(t, for: .video, position: .back) { return d }
        }
        return nil
    }

    private func configure(_ s: ConfigSnapshot) {
        guard let dev = discover(s) else { return }
        session.beginConfiguration()

        if device?.uniqueID != dev.uniqueID || videoInput == nil {
            if let old = videoInput { session.removeInput(old) }
            videoInput = nil
            if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                device = dev
            }
        }

        let preset: AVCaptureSession.Preset
        switch s.mode {
        case .video, .slowMo, .timelapse: preset = .high
        case .longExposure: preset = .hd1920x1080
        default: preset = .photo
        }
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if !session.outputs.contains(dataOutput) {
            dataOutput.alwaysDiscardsLateVideoFrames = true
            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            dataOutput.setSampleBufferDelegate(frames, queue: frames.queue)
            if session.canAddOutput(dataOutput) { session.addOutput(dataOutput) }
        }
        if s.mode.isVideo {
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        } else if session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }
        if s.mode == .scan {
            if !session.outputs.contains(metaOutput), session.canAddOutput(metaOutput) {
                session.addOutput(metaOutput)
                metaOutput.setMetadataObjectsDelegate(self, queue: .main)
                let wanted: [AVMetadataObject.ObjectType] = [.qr, .ean13, .ean8, .code128, .code39, .upce, .pdf417, .aztec, .dataMatrix]
                metaOutput.metadataObjectTypes = wanted.filter { metaOutput.availableMetadataObjectTypes.contains($0) }
            }
        } else if session.outputs.contains(metaOutput) {
            session.removeOutput(metaOutput)
        }

        let wantsAudio = s.mode.isVideo && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if wantsAudio, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        } else if !wantsAudio, let a = audioInput {
            session.removeInput(a)
            audioInput = nil
        }
        session.commitConfiguration()

        // Output tuning depends on the active format, so it runs after the commit.
        session.beginConfiguration()
        let dims = dev.activeFormat.supportedMaxPhotoDimensions
        if s.highRes, let big = dims.last {
            photoOutput.maxPhotoDimensions = big
        } else if let mid = dims.first(where: { Int($0.width) * Int($0.height) >= 11_000_000 }) ?? dims.last {
            photoOutput.maxPhotoDimensions = mid
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = s.raw && s.mode == .pro }
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported && s.live && s.mode == .photo && !s.highRes
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported && s.mode == .portrait
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = photoOutput.isPortraitEffectsMatteDeliverySupported && s.mode == .portrait
        if let c = dataOutput.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = s.position == .front
            }
        }
        session.commitConfiguration()

        applyDeviceDefaults(dev, s)
    }

    private func applyDeviceDefaults(_ d: AVCaptureDevice, _ s: ConfigSnapshot) {
        guard (try? d.lockForConfiguration()) != nil else { return }

        let virtualUW = d.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let base: CGFloat = virtualUW ? 0.5 : 1.0
        zoomBase = base

        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        d.setExposureTargetBias(0, completionHandler: nil)
        if d.hasTorch, d.torchMode != .off { d.torchMode = .off }
        d.activeVideoMinFrameDuration = .invalid
        d.activeVideoMaxFrameDuration = .invalid
        if d.isAutoFocusRangeRestrictionSupported {
            d.autoFocusRangeRestriction = s.mode == .macro ? .near : .none
        }

        if s.mode.isVideo, let pick = pickFormat(d, width: s.mode == .slowMo ? 1920 : s.videoWidth,
                                                   fps: s.mode == .slowMo ? 240 : s.fps, slowMo: s.mode == .slowMo) {
            d.activeFormat = pick.0
            let dur = CMTime(value: 1, timescale: Int32(pick.1))
            d.activeVideoMinFrameDuration = dur
            d.activeVideoMaxFrameDuration = dur
        }

        var star: (Double, Float, Double)?
        switch s.mode {
        case .night:
            let f = d.activeFormat
            let minFR = f.videoSupportedFrameRateRanges.map { $0.minFrameRate }.min() ?? 15
            setFrameDuration(d, seconds: 1.0 / max(minFR, 4.0), maxOnly: true)
        case .stars, .trails:
            star = applyStarPreset(d)
        default: break
        }

        // Zoom
        let switchOvers = d.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var buttons: [CGFloat] = [virtualUW ? 0.5 : 1.0] + switchOvers.map { $0 * base }
        if s.position == .front { buttons = [1] }
        let minZ = d.minAvailableVideoZoomFactor * base
        let maxZ = min(d.maxAvailableVideoZoomFactor * base, 20)
        var startZoom: CGFloat = 1
        if s.mode == .portrait, let tele = buttons.first(where: { $0 >= 2 }) { startZoom = tele }
        startZoom = min(max(startZoom, minZ), maxZ)
        d.videoZoomFactor = min(max(startZoom / base, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)

        let f = d.activeFormat
        let expMin = max(f.minExposureDuration.seconds, 0.00005)
        let expMax = max(min(f.maxExposureDuration.seconds, 30), expMin * 2)
        let isoLo = f.minISO, isoHi = f.maxISO
        let dims = f.supportedMaxPhotoDimensions
        let big = (dims.last.map { Int($0.width) * Int($0.height) } ?? 0) > 20_000_000
        let hasFlash = d.hasFlash, hasTorch = d.hasTorch
        let raw = photoOutput.isAppleProRAWSupported || !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let live = photoOutput.isLivePhotoCaptureSupported
        let depth = photoOutput.isDepthDataDeliverySupported
        d.unlockForConfiguration()

        DispatchQueue.main.async {
            self.lensButtons = buttons
            self.minZoom = minZ
            self.maxZoom = maxZ
            self.zoomDisplay = startZoom
            self.shutterRange = expMin...expMax
            self.isoRange = isoLo...isoHi
            self.hasFlash = hasFlash
            self.hasTorch = hasTorch
            self.supportsRAW = raw
            self.supportsLive = live
            self.supports48 = big
            self.supportsDepth = depth
            if let (dur, iso, k) = star {
                self.manualExposure = true
                self.manualFocus = true
                self.manualWB = true
                self.shutterT = self.shutterToT(dur)
                self.isoT = self.isoToT(iso)
                self.focusT = 1.0
                self.kelvin = k
            }
        }
    }

    private func pickFormat(_ d: AVCaptureDevice, width: Int32, fps: Double, slowMo: Bool) -> (AVCaptureDevice.Format, Double)? {
        let targets: [Double] = slowMo ? [240, 120] : [fps]
        for target in targets {
            for f in d.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                guard dims.width == width else { continue }
                if f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= target && target <= $0.maxFrameRate }) {
                    return (f, target)
                }
            }
        }
        var best: (AVCaptureDevice.Format, Double)?
        for f in d.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width == width else { continue }
            let mx = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
            if best == nil || mx > best!.1 { best = (f, mx.rounded(.down)) }
        }
        return best
    }

    private func setFrameDuration(_ d: AVCaptureDevice, seconds: Double, maxOnly: Bool = false) {
        let ranges = d.activeFormat.videoSupportedFrameRateRanges
        guard let slowest = ranges.min(by: { $0.minFrameRate < $1.minFrameRate }),
              let fastest = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        let fps = 1.0 / seconds
        let dur: CMTime
        if fps <= slowest.minFrameRate { dur = slowest.maxFrameDuration }
        else if fps >= fastest.maxFrameRate { dur = fastest.minFrameDuration }
        else { dur = CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
        if maxOnly {
            d.activeVideoMaxFrameDuration = dur
        } else {
            d.activeVideoMinFrameDuration = dur
            d.activeVideoMaxFrameDuration = dur
        }
    }

    /// Best-practice astro settings: infinity focus, longest exposure the format allows, high ISO, cool white balance.
    private func applyStarPreset(_ d: AVCaptureDevice) -> (Double, Float, Double) {
        let f = d.activeFormat
        let minFR = f.videoSupportedFrameRateRanges.map { $0.minFrameRate }.min() ?? 1
        let cap = min(f.maxExposureDuration.seconds, 1.0 / max(minFR, 0.5), 1.0)
        let dur = max(cap, f.minExposureDuration.seconds)
        let iso = min(max(f.minISO, 1600), f.maxISO)
        setFrameDuration(d, seconds: dur)
        d.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
        if d.isLockingFocusWithCustomLensPositionSupported { d.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil) }
        lockWhiteBalance(d, kelvin: 4000)
        return (dur, iso, 4000)
    }

    private func lockWhiteBalance(_ d: AVCaptureDevice, kelvin: Double) {
        guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
        let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvin), tint: 0)
        var g = d.deviceWhiteBalanceGains(for: tt)
        let mx = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), mx)
        g.greenGain = min(max(g.greenGain, 1), mx)
        g.blueGain = min(max(g.blueGain, 1), mx)
        d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
    }

    // MARK: - Mode / camera switching

    var isBusy: Bool { isRecording || isStacking || isTimelapse || countdown != nil }

    func setMode(_ m: CaptureMode) {
        guard m != mode, !isBusy else { return }
        mode = m
        resetManualState()
        scannedCode = nil
        haptic(.light)
        if let first = m.stackDurations.dropFirst(m.stackDurations.count > 1 ? 1 : 0).first { stackDuration = first }
        if m == .longExposure { stackBlend = .average } else if m == .trails { stackBlend = .lighten } else { stackBlend = .average }
        showToast(m.blurb)
        updateFrameConfig()
        if m.isVideo { ensureMic { self.reconfigure() } } else { reconfigure() }
    }

    private func ensureMic(_ done: @escaping () -> Void) {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: done) }
        } else { done() }
    }

    private func resetManualState() {
        manualExposure = false; manualFocus = false; manualWB = false
        evBias = 0
        torchOn = false
    }

    func flipCamera() {
        guard !isBusy else { return }
        position = position == .back ? .front : .back
        resetManualState()
        haptic(.medium)
        reconfigure()
    }

    // MARK: - Zoom / focus

    func setZoom(_ z: CGFloat) {
        let clamped = min(max(z, minZoom), maxZoom)
        zoomDisplay = clamped
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = min(max(clamped / self.zoomBase, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            d.unlockForConfiguration()
        }
    }

    func setZoomSmooth(_ z: CGFloat) {
        let clamped = min(max(z, minZoom), maxZoom)
        zoomDisplay = clamped
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            let target = min(max(clamped / self.zoomBase, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            d.ramp(toVideoZoomFactor: target, withRate: 6)
            d.unlockForConfiguration()
        }
        haptic(.light)
    }

    func focus(at layerPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let p = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        let mf = manualFocus, me = manualExposure
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if !mf, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = p
                d.focusMode = .autoFocus
            }
            if !me, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                d.exposurePointOfInterest = p
                d.exposureMode = .autoExpose
            }
            d.unlockForConfiguration()
        }
        haptic(.light)
    }

    // MARK: - Manual controls

    func shutterSeconds(_ t: Double) -> Double {
        let r = shutterRange
        return r.lowerBound * pow(r.upperBound / r.lowerBound, t)
    }
    func shutterToT(_ s: Double) -> Double {
        let r = shutterRange
        return min(1, max(0, log(s / r.lowerBound) / log(r.upperBound / r.lowerBound)))
    }
    func isoValue(_ t: Double) -> Float {
        let r = isoRange
        return r.lowerBound * pow(r.upperBound / r.lowerBound, Float(t))
    }
    func isoToT(_ v: Float) -> Double {
        let r = isoRange
        return Double(min(1, max(0, log(v / r.lowerBound) / log(r.upperBound / r.lowerBound))))
    }

    func applyExposure() {
        let manual = manualExposure
        let dur = shutterSeconds(shutterT)
        let iso = isoValue(isoT)
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if manual {
                if dur > 1.0 / 30.0 { self.setFrameDuration(d, seconds: dur) } else {
                    d.activeVideoMinFrameDuration = .invalid; d.activeVideoMaxFrameDuration = .invalid
                }
                let f = d.activeFormat
                let clampedDur = min(max(dur, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                let clampedISO = min(max(iso, f.minISO), f.maxISO)
                d.setExposureModeCustom(duration: CMTime(seconds: clampedDur, preferredTimescale: 1_000_000),
                                        iso: clampedISO, completionHandler: nil)
            } else {
                d.activeVideoMinFrameDuration = .invalid; d.activeVideoMaxFrameDuration = .invalid
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
            d.unlockForConfiguration()
        }
    }

    func applyFocus() {
        let manual = manualFocus
        let pos = Float(focusT)
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if manual, d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
            } else if !manual, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
            d.unlockForConfiguration()
        }
    }

    func applyWhiteBalance() {
        let manual = manualWB
        let k = kelvin
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if manual { self.lockWhiteBalance(d, kelvin: k) }
            else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            d.unlockForConfiguration()
        }
    }

    func applyEV() {
        let bias = evBias
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.setExposureTargetBias(min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
            d.unlockForConfiguration()
        }
    }

    func toggleTorch() {
        torchOn.toggle()
        let on = torchOn
        queue.async {
            guard let d = self.device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            if on { try? d.setTorchModeOn(level: 1.0) } else { d.torchMode = .off }
            d.unlockForConfiguration()
        }
    }

    // MARK: - Frame processor config

    func updateFrameConfig() {
        var c = FrameConfig()
        c.filter = filter.isIdentity ? nil : filter
        c.intensity = filterIntensity
        c.peaking = defaults.flag(Keys.peaking)
        c.histogram = defaults.flag(Keys.histogram)
        c.wantsSample = wantsFilterSamples
        frames.update(c)
    }

    // MARK: - Shutter

    func shutterTapped() {
        if isRecording { toggleRecording(); return }
        if isStacking { frames.finishStackNow(); return }
        if isTimelapse { toggleTimelapse(); return }
        if countdown != nil { cancelCountdown(); return }
        let fire: () -> Void = { [weak self] in self?.fire() }
        if timer > 0 && !mode.isVideo && mode != .scan && mode != .timelapse {
            runCountdown(timer, then: fire)
        } else {
            fire()
        }
    }

    private func fire() {
        switch mode {
        case .photo, .portrait, .pro, .macro: capturePhoto()
        case .night, .stars, .trails, .longExposure: startStack()
        case .video, .slowMo: toggleRecording()
        case .timelapse: toggleTimelapse()
        case .scan: break
        }
    }

    private var countdownWork: DispatchWorkItem?
    private func runCountdown(_ seconds: Int, then done: @escaping () -> Void) {
        countdown = seconds
        func tick(_ remaining: Int) {
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, self.countdown != nil else { return }
                if remaining <= 1 { self.countdown = nil; done() } else {
                    self.countdown = remaining - 1
                    self.haptic(.light)
                    tick(remaining - 1)
                }
            }
            countdownWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
        }
        tick(seconds)
    }

    private func cancelCountdown() {
        countdownWork?.cancel()
        countdown = nil
    }

    func startBurst() {
        guard mode.isStill, !burstActive else { return }
        burstActive = true
        capturePhoto()
        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in self?.capturePhoto() }
    }

    func endBurst() {
        burstTimer?.invalidate(); burstTimer = nil
        burstActive = false
    }

    // MARK: - Photo capture

    private func makeSnapshot() -> CaptureSnapshot {
        let orient = UIDevice.current.orientation
        return CaptureSnapshot(mode: mode, flash: flash, raw: defaults.flag(Keys.raw), live: defaults.flag(Keys.live),
                               heif: defaults.flag(Keys.heif), keepOriginal: defaults.flag(Keys.keepOriginal),
                               aspect: mode.usesAspect ? aspect : .fourThree, filter: filter, intensity: filterIntensity,
                               orientation: orient.isValidInterfaceOrientation ? orient : .portrait,
                               location: defaults.flag(Keys.geotag) ? location.latest : nil)
    }

    func capturePhoto() {
        let s = makeSnapshot()
        queue.async { self.doCapture(s) }
    }

    private func doCapture(_ s: CaptureSnapshot) {
        guard session.isRunning else { return }
        var settings: AVCapturePhotoSettings
        var wantsRAW = false
        if s.raw, s.mode == .pro,
           let fmt = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                ?? photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: fmt, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
            wantsRAW = true
        } else if s.heif, photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        if !wantsRAW {
            if photoOutput.supportedFlashModes.contains(s.flash.avMode) { settings.flashMode = s.flash.avMode }
            settings.photoQualityPrioritization = .quality
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        var liveURL: URL?
        if s.live, s.mode == .photo, photoOutput.isLivePhotoCaptureEnabled, !wantsRAW {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            settings.livePhotoMovieFileURL = url
            liveURL = url
        }
        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true
            if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
                settings.embedsPortraitEffectsMatteInPhoto = true
            }
        }
        if let c = photoOutput.connection(with: .video), c.isVideoOrientationSupported {
            c.videoOrientation = s.orientation.avOrientation
        }
        _ = liveURL
        let delegate = PhotoDelegate(snapshot: s,
                                     onShutter: { [weak self] in self?.flashShutter() },
                                     onDone: { [weak self] id, ok in
            self?.queue.async { self?.inFlight[id] = nil }
            if ok { self?.photoSaved() }
        })
        inFlight[settings.uniqueID] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func flashShutter() {
        DispatchQueue.main.async {
            self.captureFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.captureFlash = false }
            self.haptic(.medium)
        }
    }

    private func photoSaved() {
        DispatchQueue.main.async { self.refreshThumbnail() }
    }

    // MARK: - Stacking (Night / Stars / Trails / Long exposure)

    private func startStack() {
        guard !isStacking else { return }
        stackSnapshot = makeSnapshot()
        stackOrientation = stackSnapshot?.orientation ?? .portrait
        isStacking = true
        stackProgress = 0
        stackFrames = 0
        flashShutter()
        frames.startStack(blend: stackBlend, duration: Double(stackDuration), align: mode.alignsFrames)
    }

    private func stackFinished(_ image: CIImage?, count: Int) {
        isStacking = false
        stackProgress = 0
        previewImage = nil
        updateFrameConfig()
        guard let image = image, count > 1, let snap = stackSnapshot else {
            if image == nil && count == 0 { /* cancelled */ } else { showToast("Not enough frames captured") }
            return
        }
        showToast("Processing \(count) frames…")
        DispatchQueue.global(qos: .userInitiated).async {
            var img = image.oriented(snap.orientation.imageOrientation)
            let o = img.extent
            img = img.transformed(by: CGAffineTransform(translationX: -o.minX, y: -o.minY))
            var adj = Adjustments()
            if snap.mode == .stars {
                adj.exposure = ImagePipeline.autoStretchEV(img)
                adj.contrast = 1.12
                adj.saturation = 1.12
                adj.shadows = 0.25
            }
            let out = ImagePipeline.process(img, filter: snap.filter, intensity: snap.intensity,
                                            adjustments: adj, aspect: snap.aspect)
            guard let data = ImagePipeline.encode(out, heif: snap.heif) else {
                DispatchQueue.main.async { self.showToast("Could not save stacked image") }
                return
            }
            PhotoSaver.savePhoto(data, location: snap.location) { ok in
                self.showToast(ok ? "Saved stacked photo (\(count) frames)" : "Could not save to Photos")
                self.refreshThumbnail()
            }
        }
    }

    // MARK: - Video

    func toggleRecording() {
        if isRecording {
            queue.async { self.movieOutput.stopRecording() }
            return
        }
        let orient = UIDevice.current.orientation
        queue.async {
            guard self.session.outputs.contains(self.movieOutput), !self.movieOutput.isRecording else { return }
            if let c = self.movieOutput.connection(with: .video) {
                if c.isVideoOrientationSupported {
                    c.videoOrientation = (orient.isValidInterfaceOrientation ? orient : .portrait).avOrientation
                }
                if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
                if self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: c)
                }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordSeconds = 0
                self.haptic(.heavy)
                self.recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordSeconds += 1 }
            }
        }
    }

    // MARK: - Time-lapse

    func toggleTimelapse() {
        if isTimelapse {
            isTimelapse = false
            frames.stopTimelapse { [weak self] url in
                guard let self = self else { return }
                guard let url = url else { self.showToast("Time-lapse had no frames"); return }
                PhotoSaver.saveVideo(url, location: self.defaults.flag(Keys.geotag) ? self.location.latest : nil) { ok in
                    self.showToast(ok ? "Time-lapse saved" : "Could not save time-lapse")
                    self.refreshThumbnail()
                }
            }
        } else {
            timelapseFrames = 0
            isTimelapse = true
            haptic(.heavy)
            let interval = Double(max(defaults.integer(forKey: Keys.timelapseInterval), 1))
            frames.startTimelapse(interval: interval)
        }
    }

    // MARK: - Misc

    func refreshThumbnail() {
        PhotoSaver.latestThumbnail { [weak self] img in
            if let img = img { self?.thumbnail = img }
        }
    }

    func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            self.toastWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.toast = nil }
            self.toastWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: w)
        }
    }

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard defaults.flag(Keys.haptics) else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func locationSettingChanged() {
        if defaults.flag(Keys.geotag) { location.start() } else { location.stop() }
    }
}

// MARK: - Movie recording delegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let finishedOK = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        DispatchQueue.main.async {
            self.recordTimer?.invalidate(); self.recordTimer = nil
            self.isRecording = false
        }
        guard finishedOK else { try? FileManager.default.removeItem(at: outputFileURL); return }
        PhotoSaver.saveVideo(outputFileURL, location: defaults.flag(Keys.geotag) ? location.latest : nil) { ok in
            self.showToast(ok ? "Video saved" : "Could not save video")
            self.refreshThumbnail()
        }
    }
}

// MARK: - QR / barcode

extension CameraManager: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard mode == .scan,
              let obj = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = obj.stringValue else { return }
        if scannedCode != value { haptic(.medium) }
        scannedCode = value
        qrClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scannedCode = nil }
        qrClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }
}

// MARK: - Photo delegate

final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let snap: CaptureSnapshot
    private let onShutter: () -> Void
    private let onDone: (Int64, Bool) -> Void
    private var processed: Data?
    private var raw: Data?
    private var liveURL: URL?
    private var failed = false

    init(snapshot: CaptureSnapshot, onShutter: @escaping () -> Void, onDone: @escaping (Int64, Bool) -> Void) {
        self.snap = snapshot; self.onShutter = onShutter; self.onDone = onDone
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onShutter()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error != nil { failed = true; return }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { raw = data } else { processed = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error == nil { liveURL = outputFileURL }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let id = resolvedSettings.uniqueID
        guard error == nil, !failed, let original = processed ?? raw else { onDone(id, false); return }
        let s = snap
        let live = liveURL
        let rawData = raw
        let main = processed
        DispatchQueue.global(qos: .userInitiated).async {
            if let main = main, s.needsProcessing, live == nil,
               let out = ImagePipeline.processPhotoData(main, filter: s.filter, intensity: s.intensity,
                                                        adjustments: Adjustments(), aspect: s.aspect, heif: s.heif) {
                PhotoSaver.savePhoto(out, raw: rawData, location: s.location)
                if s.keepOriginal { PhotoSaver.savePhoto(main, location: s.location) }
            } else {
                PhotoSaver.savePhoto(main ?? original, raw: main == nil ? nil : rawData, liveMovie: live, location: s.location)
            }
            self.onDone(id, true)
        }
    }
}

// MARK: - Location

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        latest = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latest = locations.last
    }
}
