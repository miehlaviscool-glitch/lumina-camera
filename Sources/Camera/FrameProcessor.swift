import AVFoundation
import CoreImage
import Vision
import UIKit

struct FrameConfig {
    var filter: LuminaFilter?
    var intensity = 1.0
    var peaking = false
    var histogram = false
    var wantsSample = false
}

private final class StackJob {
    let blend: StackBlend
    let duration: Double
    let align: Bool
    var count = 0
    let start = CACurrentMediaTime()
    var acc: CVPixelBuffer?
    var scratch: CVPixelBuffer?
    var reference: CIImage?
    var finishRequested = false
    init(blend: StackBlend, duration: Double, align: Bool) {
        self.blend = blend; self.duration = duration; self.align = align
    }
}

private final class TimelapseJob {
    let interval: Double
    let url: URL
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    var frameIndex = 0
    var lastCapture: CFTimeInterval = 0
    init(interval: Double) {
        self.interval = interval
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    }
}

/// Receives every camera frame. Drives live filter preview, histogram, focus peaking,
/// multi-frame stacking (night / stars / trails / long exposure) and time-lapse writing.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "lumina.frames", qos: .userInitiated)
    private let context = ImagePipeline.context
    private var config = FrameConfig()
    private var stack: StackJob?
    private var timelapse: TimelapseJob?
    private var counter = 0
    private var previewShown = false

    // All callbacks are delivered on the main queue.
    var onPreview: ((CGImage?) -> Void)?
    var onHistogram: (([Float]) -> Void)?
    var onSample: ((CGImage) -> Void)?
    var onStackProgress: ((Double, Int) -> Void)?
    var onStackFinished: ((CIImage?, Int) -> Void)?
    var onTimelapseFrames: ((Int) -> Void)?

    func update(_ c: FrameConfig) { queue.async { self.config = c } }

    // MARK: - Stacking

    func startStack(blend: StackBlend, duration: Double, align: Bool) {
        queue.async { self.stack = StackJob(blend: blend, duration: duration, align: align) }
    }

    func finishStackNow() { queue.async { self.stack?.finishRequested = true } }

    func cancelStack() {
        queue.async {
            self.stack = nil
            DispatchQueue.main.async { self.onStackFinished?(nil, 0) }
        }
    }

    // MARK: - Time-lapse

    func startTimelapse(interval: Double) { queue.async { self.timelapse = TimelapseJob(interval: interval) } }

    func stopTimelapse(completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let job = self.timelapse else { DispatchQueue.main.async { completion(nil) }; return }
            self.timelapse = nil
            guard let writer = job.writer, let input = job.input, job.frameIndex > 0 else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            input.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async { completion(writer.status == .completed ? job.url : nil) }
            }
        }
    }

    // MARK: - Frame delivery

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        counter += 1
        let frame = CIImage(cvPixelBuffer: pb)
        let cfg = config

        if let job = stack {
            handleStack(job, frame)
            return
        }
        if let job = timelapse { handleTimelapse(job, frame, cfg) }

        if cfg.histogram, counter % 6 == 0 { publishHistogram(frame) }
        if cfg.wantsSample, counter % 40 == 1 { publishSample(frame) }

        let active = (cfg.filter.map { !$0.isIdentity } ?? false) || cfg.peaking
        if active {
            var img = ImagePipeline.scale(frame, maxSide: 1280)
            if let f = cfg.filter, !f.isIdentity {
                let e = img.extent
                let filtered = f.transform(img).cropped(to: e)
                img = cfg.intensity < 0.995
                    ? img.lf("CIDissolveTransition", ["inputTargetImage": filtered, "inputTime": cfg.intensity]).cropped(to: e)
                    : filtered
            }
            if cfg.peaking { img = applyPeaking(img) }
            if let cg = context.createCGImage(img, from: img.extent) {
                previewShown = true
                DispatchQueue.main.async { self.onPreview?(cg) }
            }
        } else if previewShown {
            previewShown = false
            DispatchQueue.main.async { self.onPreview?(nil) }
        }
    }

    private func applyPeaking(_ img: CIImage) -> CIImage {
        let e = img.extent
        let edges = img.lf("CIEdges", ["inputIntensity": 6.0])
            .lf("CIColorControls", ["inputContrast": 3.0, "inputBrightness": -0.2])
            .lf("CIColorMatrix", [
                "inputRVector": CIVector(x: 1, y: 1, z: 1, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 1, y: 1, z: 1, w: 0)
            ]).cropped(to: e)
        return edges.lf("CISourceOverCompositing", [kCIInputBackgroundImageKey: img]).cropped(to: e)
    }

    private func publishHistogram(_ frame: CIImage) {
        let small = ImagePipeline.scale(frame, maxSide: 256)
        let bins = 64
        let hist = small.lf("CIAreaHistogram", [
            "inputExtent": CIVector(cgRect: small.extent), "inputScale": 1.0, "inputCount": bins
        ])
        var data = [Float](repeating: 0, count: bins * 4)
        context.render(hist, toBitmap: &data, rowBytes: bins * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
        var luma = (0..<bins).map { 0.299 * data[$0 * 4] + 0.587 * data[$0 * 4 + 1] + 0.114 * data[$0 * 4 + 2] }
        let peak = max(luma.max() ?? 1, 0.0001)
        luma = luma.map { sqrt($0 / peak) }
        DispatchQueue.main.async { self.onHistogram?(luma) }
    }

    private func publishSample(_ frame: CIImage) {
        let small = ImagePipeline.scale(frame, maxSide: 180)
        if let cg = context.createCGImage(small, from: small.extent) {
            DispatchQueue.main.async { self.onSample?(cg) }
        }
    }

    // MARK: - Stack processing

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb)
        return pb
    }

    private func handleStack(_ job: StackJob, _ rawFrame: CIImage) {
        var img = ImagePipeline.scale(rawFrame, maxSide: 3200)
        let extent = CGRect(x: 0, y: 0, width: img.extent.width.rounded(.down), height: img.extent.height.rounded(.down))
        img = img.cropped(to: extent)

        if job.count == 0 {
            job.acc = makeBuffer(Int(extent.width), Int(extent.height))
            job.scratch = makeBuffer(Int(extent.width), Int(extent.height))
            guard let acc = job.acc, job.scratch != nil else { fail(); return }
            context.render(img, to: acc, bounds: extent, colorSpace: ImagePipeline.linear)
            if job.align { job.reference = ImagePipeline.scale(img, maxSide: 480) }
        } else if let acc = job.acc, let scratch = job.scratch {
            if job.align, let ref = job.reference { img = align(img, to: ref, extent: extent) }
            let accImg = CIImage(cvPixelBuffer: acc, options: [.colorSpace: ImagePipeline.linear])
            let combined: CIImage
            switch job.blend {
            case .average:
                let n = CGFloat(job.count + 1)
                let a = accImg.lf("CIColorMatrix", [
                    "inputRVector": CIVector(x: (n - 1) / n, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: (n - 1) / n, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: (n - 1) / n, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                let f = img.lf("CIColorMatrix", [
                    "inputRVector": CIVector(x: 1 / n, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 / n, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 / n, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
                combined = f.lf("CIAdditionCompositing", [kCIInputBackgroundImageKey: a])
            case .lighten:
                combined = img.lf("CILightenBlendMode", [kCIInputBackgroundImageKey: accImg])
            }
            context.render(combined, to: scratch, bounds: extent, colorSpace: ImagePipeline.linear)
            job.acc = scratch
            job.scratch = acc
        }
        job.count += 1

        let elapsed = CACurrentMediaTime() - job.start
        let progress = min(1, elapsed / job.duration)
        let count = job.count
        DispatchQueue.main.async { self.onStackProgress?(progress, count) }

        if job.count % 3 == 0, let acc = job.acc {
            let live = ImagePipeline.scale(CIImage(cvPixelBuffer: acc, options: [.colorSpace: ImagePipeline.linear]), maxSide: 1000)
            if let cg = context.createCGImage(live, from: live.extent) {
                previewShown = true
                DispatchQueue.main.async { self.onPreview?(cg) }
            }
        }

        if progress >= 1 || job.finishRequested {
            stack = nil
            let result = job.acc.map { CIImage(cvPixelBuffer: $0, options: [.colorSpace: ImagePipeline.linear]) }
            DispatchQueue.main.async { self.onStackFinished?(result, count) }
        }
    }

    private func fail() {
        stack = nil
        DispatchQueue.main.async { self.onStackFinished?(nil, 0) }
    }

    /// Translational registration against the first frame so handheld Night captures line up.
    private func align(_ img: CIImage, to ref: CIImage, extent: CGRect) -> CIImage {
        let small = ImagePipeline.scale(img, maxSide: 480)
        let req = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
        let handler = VNImageRequestHandler(ciImage: ref, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first as? VNImageTranslationAlignmentObservation else { return img }
        let k = extent.width / max(small.extent.width, 1)
        let t = obs.alignmentTransform
        return img.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: t.tx * k, y: t.ty * k))
            .cropped(to: extent)
    }

    // MARK: - Time-lapse processing

    private func handleTimelapse(_ job: TimelapseJob, _ frame: CIImage, _ cfg: FrameConfig) {
        let now = CACurrentMediaTime()
        guard job.frameIndex == 0 || now - job.lastCapture >= job.interval else { return }
        job.lastCapture = now

        var img = ImagePipeline.scale(frame, maxSide: 1920)
        let w = Int(img.extent.width) & ~1, h = Int(img.extent.height) & ~1
        img = img.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        if let f = cfg.filter, !f.isIdentity {
            let e = img.extent
            let filtered = f.transform(img).cropped(to: e)
            img = cfg.intensity < 0.995
                ? img.lf("CIDissolveTransition", ["inputTargetImage": filtered, "inputTime": cfg.intensity]).cropped(to: e)
                : filtered
        }

        if job.writer == nil {
            guard let writer = try? AVAssetWriter(outputURL: job.url, fileType: .mp4) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
            guard writer.canAdd(input) else { return }
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            job.writer = writer; job.input = input; job.adaptor = adaptor
        }
        guard let input = job.input, let adaptor = job.adaptor, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { return }
        context.render(img, to: buffer)
        if adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(job.frameIndex), timescale: 30)) {
            job.frameIndex += 1
            let n = job.frameIndex
            DispatchQueue.main.async { self.onTimelapseFrames?(n) }
        }
    }
}
