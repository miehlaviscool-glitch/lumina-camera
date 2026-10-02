import SwiftUI

// MARK: - Pro manual panel

struct ProPanel: View {
    @ObservedObject var cam: CameraManager

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(ProTab.allCases) { tab in
                    Button { cam.proTab = tab } label: {
                        Chip(title: tab.rawValue, selected: cam.proTab == tab)
                    }
                }
            }
            HStack(spacing: 10) {
                Text(valueText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 84, alignment: .leading)
                slider
                if cam.proTab != .ev {
                    Button { toggleAuto() } label: {
                        Chip(title: "AUTO", selected: isAuto)
                    }
                }
            }
            HStack(spacing: 14) {
                Text("ISO \(Int(cam.liveISO))")
                Text(shutterString(cam.liveShutter))
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
        }
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private var isAuto: Bool {
        switch cam.proTab {
        case .iso, .shutter: return !cam.manualExposure
        case .focus: return !cam.manualFocus
        case .wb: return !cam.manualWB
        case .ev: return true
        }
    }

    private func toggleAuto() {
        switch cam.proTab {
        case .iso, .shutter: cam.manualExposure.toggle(); cam.applyExposure()
        case .focus: cam.manualFocus.toggle(); cam.applyFocus()
        case .wb: cam.manualWB.toggle(); cam.applyWhiteBalance()
        case .ev: break
        }
    }

    private var valueText: String {
        switch cam.proTab {
        case .ev: return String(format: "%+.1f EV", cam.evBias)
        case .iso: return cam.manualExposure ? "\(Int(cam.isoValue(cam.isoT)))" : "Auto"
        case .shutter: return cam.manualExposure ? shutterString(cam.shutterSeconds(cam.shutterT)) : "Auto"
        case .focus: return cam.manualFocus ? (cam.focusT > 0.97 ? "∞" : String(format: "%.2f", cam.focusT)) : "Auto"
        case .wb: return cam.manualWB ? "\(Int(cam.kelvin))K" : "Auto"
        }
    }

    @ViewBuilder private var slider: some View {
        switch cam.proTab {
        case .ev:
            Slider(value: Binding(get: { Double(cam.evBias) }, set: { cam.evBias = Float($0); cam.applyEV() }), in: -4...4)
                .tint(gold)
        case .iso:
            Slider(value: Binding(get: { cam.isoT }, set: { cam.isoT = $0; cam.manualExposure = true; cam.applyExposure() }), in: 0...1)
                .tint(gold)
        case .shutter:
            Slider(value: Binding(get: { cam.shutterT }, set: { cam.shutterT = $0; cam.manualExposure = true; cam.applyExposure() }), in: 0...1)
                .tint(gold)
        case .focus:
            Slider(value: Binding(get: { cam.focusT }, set: { cam.focusT = $0; cam.manualFocus = true; cam.applyFocus() }), in: 0...1)
                .tint(gold)
        case .wb:
            Slider(value: Binding(get: { cam.kelvin }, set: { cam.kelvin = $0; cam.manualWB = true; cam.applyWhiteBalance() }), in: 2500...10000)
                .tint(gold)
        }
    }
}

func shutterString(_ s: Double) -> String {
    guard s > 0 else { return "-" }
    if s >= 0.5 { return String(format: "%.1fs", s) }
    return "1/\(Int((1 / s).rounded()))"
}

// MARK: - Stack (Night / Stars / Trails / Long exposure) panel

struct StackPanel: View {
    @ObservedObject var cam: CameraManager
    @Binding var showTune: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(cam.mode.stackDurations, id: \.self) { d in
                    Button { cam.stackDuration = d; cam.haptic(.light) } label: {
                        Chip(title: d >= 60 ? "\(d / 60)m" : "\(d)s", selected: cam.stackDuration == d)
                    }
                }
                if cam.mode == .longExposure {
                    Button { cam.stackBlend = cam.stackBlend == .average ? .lighten : .average } label: {
                        Chip(title: cam.stackBlend == .average ? "SMOOTH" : "TRAILS", icon: "wand.and.rays",
                             selected: cam.stackBlend == .lighten)
                    }
                }
                if cam.mode == .stars || cam.mode == .trails {
                    Button { showTune.toggle() } label: { Chip(title: "TUNE", icon: "slider.horizontal.3", selected: showTune) }
                }
            }
            if cam.mode == .stars || cam.mode == .trails {
                Text("\(shutterString(cam.shutterSeconds(cam.shutterT))) · ISO \(Int(cam.isoValue(cam.isoT))) · focus ∞ · \(cam.stackDuration)s stack")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Time-lapse panel

struct TimelapsePanel: View {
    @AppStorage(Keys.timelapseInterval) private var interval = 2
    @ObservedObject var cam: CameraManager

    var body: some View {
        HStack(spacing: 8) {
            Text("Every").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            ForEach([1, 2, 5, 10, 30], id: \.self) { s in
                Button { interval = s } label: { Chip(title: "\(s)s", selected: interval == s) }
                    .disabled(cam.isTimelapse)
            }
            if cam.isTimelapse {
                Text("\(cam.timelapseFrames) frames")
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
            }
        }
    }
}

// MARK: - Filter strip

struct FilterStrip: View {
    @ObservedObject var cam: CameraManager
    @State private var thumbs: [String: UIImage] = [:]
    private let renderQueue = DispatchQueue(label: "lumina.thumbs", qos: .utility)

    var body: some View {
        VStack(spacing: 6) {
            if !cam.filter.isIdentity {
                HStack {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 12))
                    Slider(value: $cam.filterIntensity, in: 0...1) { _ in cam.updateFrameConfig() }
                        .tint(gold)
                        .onChange(of: cam.filterIntensity) { _ in cam.updateFrameConfig() }
                    Text("\(Int(cam.filterIntensity * 100))").font(.system(size: 11, design: .monospaced)).frame(width: 28)
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LuminaFilter.all) { f in
                        Button {
                            cam.filter = f
                            cam.updateFrameConfig()
                            cam.haptic(.light)
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12))
                                    if let t = thumbs[f.id] {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    }
                                }
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(cam.filter == f ? gold : .clear, lineWidth: 2))
                                Text(f.name).font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(cam.filter == f ? gold : .white.opacity(0.8))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .onAppear { cam.wantsFilterSamples = true }
        .onDisappear { cam.wantsFilterSamples = false }
        .onReceive(cam.$sampleImage.compactMap { $0 }) { img in render(from: img) }
    }

    private func render(from cg: CGImage) {
        renderQueue.async {
            let src = CIImage(cgImage: cg)
            var out: [String: UIImage] = [:]
            for f in LuminaFilter.all {
                let img = f.transform(src).cropped(to: src.extent)
                if let o = ImagePipeline.context.createCGImage(img, from: src.extent) { out[f.id] = UIImage(cgImage: o) }
            }
            DispatchQueue.main.async { thumbs = out }
        }
    }
}
