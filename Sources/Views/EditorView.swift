import SwiftUI
import PhotosUI

struct EditorView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable { case filters = "Filters", light = "Light", color = "Color", detail = "Detail" }

    @State private var pickerItem: PhotosPickerItem?
    @State private var originalData: Data?
    @State private var source: CIImage?
    @State private var filter: LuminaFilter = .original
    @State private var intensity = 1.0
    @State private var adj = Adjustments()
    @State private var aspect: AspectRatio = .fourThree
    @State private var tab: Tab = .filters
    @State private var preview: UIImage?
    @State private var showOriginal = false
    @State private var saving = false
    @State private var message: String?
    @State private var thumbs: [String: UIImage] = [:]

    private let renderQueue = DispatchQueue(label: "lumina.editor.render", qos: .userInitiated)
    @State private var generation = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let img = showOriginal ? originalPreview : preview {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo").font(.system(size: 44)).foregroundColor(.white.opacity(0.5))
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Chip(title: "CHOOSE A PHOTO", selected: true)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if source != nil { showOriginal = true } }
                    .onEnded { _ in showOriginal = false })

                if source != nil { controls }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if source != nil {
                        PhotosPicker(selection: $pickerItem, matching: .images) { Image(systemName: "photo.on.rectangle") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(source == nil || saving)
                }
            }
            .overlay(alignment: .top) { if let m = message { ToastView(text: m).padding(.top, 8) } }
        }
        .tint(gold)
        .onChange(of: pickerItem) { item in load(item) }
        .onChange(of: filter) { _ in render() }
        .onChange(of: intensity) { _ in render() }
        .onChange(of: adj) { _ in render() }
        .onChange(of: aspect) { _ in render() }
    }

    private var originalPreview: UIImage? {
        guard let s = source, let cg = ImagePipeline.context.createCGImage(s, from: s.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            Group {
                switch tab {
                case .filters: filtersTab
                case .light:
                    VStack(spacing: 2) {
                        slider("Exposure", $adj.exposure, -2...2)
                        slider("Brightness", $adj.brightness, -0.4...0.4)
                        slider("Contrast", $adj.contrast, 0.5...1.6)
                        slider("Highlights", $adj.highlights, 0...1)
                        slider("Shadows", $adj.shadows, -1...1)
                    }
                case .color:
                    VStack(spacing: 2) {
                        slider("Saturation", $adj.saturation, 0...2)
                        slider("Vibrance", $adj.vibrance, -1...1)
                        slider("Warmth", $adj.warmth, -1...1)
                        slider("Tint", $adj.tint, -1...1)
                    }
                case .detail:
                    VStack(spacing: 2) {
                        slider("Sharpen", $adj.sharpness, 0...2)
                        slider("Vignette", $adj.vignette, 0...2)
                        slider("Grain", $adj.grain, 0...1)
                        HStack {
                            Text("Crop").font(.system(size: 12)).frame(width: 80, alignment: .leading)
                            ForEach(AspectRatio.allCases, id: \.self) { a in
                                Button { aspect = a } label: { Chip(title: a.rawValue, selected: aspect == a) }
                            }
                            Spacer()
                            Button { reset() } label: { Chip(title: "RESET", icon: "arrow.counterclockwise") }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .frame(height: 150)
        }
        .padding(.vertical, 8)
        .background(Color(white: 0.08))
    }

    private var filtersTab: some View {
        VStack(spacing: 6) {
            if !filter.isIdentity {
                HStack {
                    Text("Intensity").font(.system(size: 12)).frame(width: 80, alignment: .leading)
                    Slider(value: $intensity, in: 0...1)
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LuminaFilter.all) { f in
                        Button { filter = f } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12))
                                    if let t = thumbs[f.id] { Image(uiImage: t).resizable().scaledToFill() }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(filter == f ? gold : .clear, lineWidth: 2))
                                Text(f.name).font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(filter == f ? gold : .white.opacity(0.8))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
    }

    // MARK: Logic

    private func load(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let full = ImagePipeline.loadOriented(data) else { return }
            let small = ImagePipeline.scale(full, maxSide: 1600)
            await MainActor.run {
                originalData = data
                source = small
                filter = .original; intensity = 1; adj = Adjustments(); aspect = .fourThree
                render()
                renderThumbs()
            }
        }
    }

    private func render() {
        guard let src = source else { return }
        generation += 1
        let gen = generation
        let f = filter, i = intensity, a = adj, asp = aspect
        renderQueue.async {
            let out = ImagePipeline.process(src, filter: f, intensity: i, adjustments: a, aspect: asp)
            guard let cg = ImagePipeline.context.createCGImage(out, from: out.extent) else { return }
            let ui = UIImage(cgImage: cg)
            DispatchQueue.main.async { if gen == generation { preview = ui } }
        }
    }

    private func renderThumbs() {
        guard let src = source else { return }
        renderQueue.async {
            let small = ImagePipeline.scale(src, maxSide: 160)
            var out: [String: UIImage] = [:]
            for f in LuminaFilter.all {
                let img = f.transform(small).cropped(to: small.extent)
                if let cg = ImagePipeline.context.createCGImage(img, from: small.extent) { out[f.id] = UIImage(cgImage: cg) }
            }
            DispatchQueue.main.async { thumbs = out }
        }
    }

    private func reset() {
        filter = .original; intensity = 1; adj = Adjustments(); aspect = .fourThree
    }

    private func save() {
        guard let data = originalData else { return }
        saving = true
        let f = filter, i = intensity, a = adj, asp = aspect
        DispatchQueue.global(qos: .userInitiated).async {
            let out = ImagePipeline.processPhotoData(data, filter: f, intensity: i, adjustments: a, aspect: asp, heif: false)
            guard let out = out else {
                DispatchQueue.main.async { saving = false; flash("Could not process photo") }
                return
            }
            PhotoSaver.savePhoto(out) { ok in
                saving = false
                flash(ok ? "Saved to Photos" : "Could not save")
            }
        }
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { message = nil }
    }
}
