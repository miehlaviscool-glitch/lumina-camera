import SwiftUI
import AVFoundation

struct CameraScreen: View {
    @StateObject private var cam = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(Keys.grid) private var gridRaw = GridStyle.thirds.rawValue
    @AppStorage(Keys.level) private var showLevel = true
    @AppStorage(Keys.histogram) private var showHistogram = false
    @AppStorage(Keys.peaking) private var peaking = false
    @AppStorage(Keys.raw) private var rawOn = false
    @AppStorage(Keys.highRes) private var highRes = false
    @AppStorage(Keys.live) private var liveOn = false
    @AppStorage(Keys.nightUI) private var nightUI = false
    @AppStorage(Keys.videoRes) private var videoRes = 1920
    @AppStorage(Keys.videoFPS) private var videoFPS = 30

    @State private var showSettings = false
    @State private var showEditor = false
    @State private var showFilters = false
    @State private var showTray = false
    @State private var showTune = false
    @State private var reticle: CGPoint?
    @State private var reticleToken = 0
    @State private var pinchBase: CGFloat?
    @State private var burstWork: DispatchWorkItem?
    @State private var pressing = false

    private var accent: Color { nightUI ? Color(red: 1, green: 0.15, blue: 0.1) : gold }
    private var grid: GridStyle { GridStyle(rawValue: gridRaw) ?? .thirds }

    private var previewRatio: CGFloat {
        if cam.mode.isVideo || cam.mode == .timelapse || cam.mode == .scan { return 16.0 / 9.0 }
        return cam.mode.usesAspect ? cam.aspect.longOverShort : 4.0 / 3.0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if cam.permissionDenied {
                    permissionView
                } else {
                    previewArea(width: geo.size.width)
                        .padding(.top, geo.safeAreaInsets.top + 54)

                    VStack(spacing: 0) {
                        topBar
                        if showTray { tray.padding(.top, 6) }
                        Spacer()
                        bottomControls
                    }
                    .padding(.top, geo.safeAreaInsets.top > 0 ? 0 : 8)
                }
            }
            .overlay(nightUI ? Color.red.opacity(0.10).blendMode(.multiply).ignoresSafeArea().allowsHitTesting(false) : nil)
        }
        .tint(accent)
        .onAppear { cam.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { cam.start() } else if phase == .background { cam.pause() }
        }
        .onChange(of: highRes) { _ in cam.reconfigure() }
        .onChange(of: rawOn) { _ in cam.reconfigure() }
        .onChange(of: liveOn) { _ in cam.reconfigure() }
        .onChange(of: peaking) { _ in cam.updateFrameConfig() }
        .onChange(of: showHistogram) { _ in cam.updateFrameConfig() }
        .onChange(of: videoRes) { _ in cam.reconfigure() }
        .onChange(of: videoFPS) { _ in cam.reconfigure() }
        .sheet(isPresented: $showSettings, onDismiss: { cam.reconfigure(); cam.locationSettingChanged(); cam.updateFrameConfig() }) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showEditor, onDismiss: { cam.refreshThumbnail() }) { EditorView() }
        .animation(.easeInOut(duration: 0.2), value: cam.toast)
    }

    // MARK: Preview

    private func previewArea(width: CGFloat) -> some View {
        ZStack {
            CameraPreview(camera: cam)
                .gesture(SpatialTapGesture().onEnded { v in
                    reticle = v.location
                    reticleToken += 1
                    let token = reticleToken
                    cam.focus(at: v.location)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if token == reticleToken { reticle = nil } }
                })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { s in
                        if pinchBase == nil { pinchBase = cam.zoomDisplay }
                        cam.setZoom((pinchBase ?? 1) * s)
                    }
                    .onEnded { _ in pinchBase = nil })

            if grid != .off { GridOverlay(style: grid) }
            if showLevel && cam.mode != .scan { LevelOverlay(angle: cam.rollAngle) }
            if let r = reticle { FocusReticle().position(r).allowsHitTesting(false) }

            VStack {
                HStack {
                    if cam.isRecording { recBadge }
                    if cam.isTimelapse { tlBadge }
                    Spacer()
                    if showHistogram { HistogramView(bins: cam.histogram) }
                }
                .padding(10)
                Spacer()
                if cam.zoomDisplay != 1 || cam.lensButtons.count > 1 {
                    EmptyView()
                }
            }

            if let n = cam.countdown {
                Text("\(n)").font(.system(size: 110, weight: .thin, design: .rounded))
                    .foregroundColor(.white).shadow(radius: 8).allowsHitTesting(false)
            }
            if cam.isStacking { stackOverlay }
            if let code = cam.scannedCode { scanBanner(code) }
            if cam.captureFlash { Color.white.opacity(0.8).allowsHitTesting(false) }

            VStack {
                if let t = cam.toast { ToastView(text: t).padding(.top, 8) }
                Spacer()
            }
        }
        .frame(width: width, height: width * previewRatio)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: previewRatio)
    }

    private var recBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(timeString(cam.recordSeconds)).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    private var tlBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("\(cam.timelapseFrames) fr").font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    private var stackOverlay: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 5)
                Circle().trim(from: 0, to: cam.stackProgress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(cam.stackProgress * 100))%").font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            .frame(width: 84, height: 84)
            Text("\(cam.stackFrames) frames · tap shutter to finish")
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .allowsHitTesting(false)
    }

    private func scanBanner(_ code: String) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Text(code).font(.system(size: 14, design: .monospaced)).lineLimit(3)
                HStack(spacing: 10) {
                    Button { UIPasteboard.general.string = code; cam.showToast("Copied") } label: { Chip(title: "COPY", icon: "doc.on.doc") }
                    if let url = URL(string: code), UIApplication.shared.canOpenURL(url), url.scheme?.hasPrefix("http") == true {
                        Button { UIApplication.shared.open(url) } label: { Chip(title: "OPEN", icon: "safari", selected: true) }
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 16).padding(.horizontal, 16)
        }
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 44))
            Text("Camera access needed").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Enable camera access for Lumina in Settings.").foregroundColor(.white.opacity(0.7))
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            if cam.mode.isVideo || cam.mode == .scan {
                if cam.hasTorch {
                    barButton(cam.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", active: cam.torchOn) { cam.toggleTorch() }
                } else { Spacer().frame(maxWidth: .infinity) }
            } else if cam.mode.isStill {
                if cam.hasFlash && cam.position == .back {
                    barButton(cam.flash.icon, active: cam.flash != .off) { cam.flash = cam.flash.next }
                } else { Spacer().frame(maxWidth: .infinity) }
            } else { Spacer().frame(maxWidth: .infinity) }

            if cam.mode == .photo && cam.supportsLive {
                barButton(liveOn ? "livephoto" : "livephoto.slash", active: liveOn) { liveOn.toggle() }
            } else if cam.mode.isVideo {
                Menu {
                    Picker("Resolution", selection: $videoRes) {
                        Text("720p").tag(1280); Text("1080p").tag(1920); Text("4K").tag(3840)
                    }
                    Picker("Frame rate", selection: $videoFPS) {
                        Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }
                } label: {
                    Text(cam.mode == .slowMo ? "240" : "\(videoRes == 3840 ? "4K" : videoRes == 1920 ? "HD" : "HD-")·\(videoFPS)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .disabled(cam.mode == .slowMo || cam.isRecording)
            } else { Spacer().frame(maxWidth: .infinity) }

            if cam.mode != .scan {
                barButton(cam.timer == 0 ? "timer" : "timer", label: cam.timer == 0 ? nil : "\(cam.timer)s", active: cam.timer > 0) {
                    cam.timer = cam.timer == 0 ? 3 : (cam.timer == 3 ? 10 : 0)
                }
            } else { Spacer().frame(maxWidth: .infinity) }

            if cam.mode.usesAspect {
                Button { cam.aspect = cam.aspect.next } label: {
                    Text(cam.aspect.rawValue).font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
            } else { Spacer().frame(maxWidth: .infinity) }

            if cam.mode != .scan {
                barButton("camera.filters", active: showFilters || !cam.filter.isIdentity) { withAnimation { showFilters.toggle() } }
            } else { Spacer().frame(maxWidth: .infinity) }

            barButton(showTray ? "chevron.up" : "chevron.down") { withAnimation { showTray.toggle() } }
            barButton("gearshape") { showSettings = true }
        }
        .foregroundColor(.white)
        .frame(height: 48)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.0001))
    }

    private func barButton(_ icon: String, label: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                if let l = label { Text(l).font(.system(size: 11, weight: .bold)) }
            }
            .foregroundColor(active ? accent : .white)
            .frame(maxWidth: .infinity, minHeight: 38)
        }
    }

    private var tray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { gridRaw = grid.next.rawValue } label: { Chip(title: "GRID " + grid.rawValue.uppercased(), icon: "grid", selected: grid != .off) }
                Button { showLevel.toggle() } label: { Chip(title: "LEVEL", icon: "level", selected: showLevel) }
                Button { showHistogram.toggle() } label: { Chip(title: "HISTOGRAM", icon: "chart.bar", selected: showHistogram) }
                Button { peaking.toggle() } label: { Chip(title: "PEAKING", icon: "viewfinder", selected: peaking) }
                if cam.supportsRAW && cam.mode == .pro {
                    Button { rawOn.toggle() } label: { Chip(title: "RAW", selected: rawOn) }
                }
                if cam.supports48 && cam.mode.isStill {
                    Button { highRes.toggle() } label: { Chip(title: "MAX RES", selected: highRes) }
                }
                Button { nightUI.toggle() } label: { Chip(title: "NIGHT VISION", icon: "eye", selected: nightUI) }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Bottom

    private var bottomControls: some View {
        VStack(spacing: 8) {
            if cam.mode == .pro || ((cam.mode == .stars || cam.mode == .trails) && showTune) {
                ProPanel(cam: cam)
            }
            if cam.mode.isStack { StackPanel(cam: cam, showTune: $showTune) }
            if cam.mode == .timelapse { TimelapsePanel(cam: cam) }
            if showFilters && cam.mode != .scan { FilterStrip(cam: cam).transition(.opacity) }
            if cam.mode != .scan && cam.position == .back && cam.lensButtons.count > 1 { lensRow }
            modeCarousel
            shutterRow
        }
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -30).ignoresSafeArea()
        )
    }

    private var lensRow: some View {
        HStack(spacing: 8) {
            ForEach(cam.lensButtons, id: \.self) { z in
                let selected = abs(cam.zoomDisplay - z) < 0.05
                Button { cam.setZoomSmooth(z) } label: {
                    Text(selected ? zoomString(z) + "x" : zoomString(z))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? .black : .white)
                        .frame(width: 38, height: 38)
                        .background(selected ? accent : Color.black.opacity(0.45), in: Circle())
                }
            }
            if !cam.lensButtons.contains(where: { abs(cam.zoomDisplay - $0) < 0.05 }) {
                Text(zoomString(cam.zoomDisplay) + "x")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(accent)
            }
        }
    }

    private func zoomString(_ z: CGFloat) -> String {
        z.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", z) : String(format: "%.1f", z)
    }

    private var modeCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(CaptureMode.allCases) { m in
                        Button { withAnimation { cam.setMode(m) } } label: {
                            Text(m.title)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(cam.mode == m ? accent : .white.opacity(0.75))
                        }
                        .id(m)
                    }
                }
                .padding(.horizontal, 160)
            }
            .frame(height: 30)
            .onChange(of: cam.mode) { m in withAnimation { proxy.scrollTo(m, anchor: .center) } }
        }
    }

    private var shutterRow: some View {
        HStack {
            Button { showEditor = true } label: {
                Group {
                    if let t = cam.thumbnail {
                        Image(uiImage: t).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 20))
                    }
                }
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.4), lineWidth: 1))
            }
            .frame(maxWidth: .infinity)

            shutterButton.frame(maxWidth: .infinity)

            Button { cam.flipCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 22)).foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .disabled(cam.isBusy)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
    }

    private var shutterButton: some View {
        let recording = cam.isRecording || cam.isTimelapse
        let video = cam.mode.isVideo || cam.mode == .timelapse
        return ZStack {
            Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
            if cam.isStacking {
                Circle().trim(from: 0, to: cam.stackProgress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: 6).fill(accent).frame(width: 30, height: 30)
            } else if recording {
                RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
            } else {
                Circle().fill(video ? Color.red : (cam.mode.isStack ? accent : Color.white))
                    .frame(width: 64, height: 64)
                    .scaleEffect(pressing ? 0.88 : 1)
            }
            if cam.burstActive {
                Circle().stroke(accent, lineWidth: 3).frame(width: 90, height: 90)
            }
        }
        .contentShape(Circle())
        .opacity(cam.mode == .scan ? 0.35 : 1)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing else { return }
                pressing = true
                guard cam.mode.isStill else { return }
                let w = DispatchWorkItem { cam.startBurst() }
                burstWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
            }
            .onEnded { _ in
                pressing = false
                burstWork?.cancel()
                if cam.burstActive { cam.endBurst() } else { cam.shutterTapped() }
            })
        .animation(.easeOut(duration: 0.12), value: pressing)
    }

    private func timeString(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
}
