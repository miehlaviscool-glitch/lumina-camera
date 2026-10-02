import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.heif) private var heif = true
    @AppStorage(Keys.keepOriginal) private var keepOriginal = false
    @AppStorage(Keys.geotag) private var geotag = false
    @AppStorage(Keys.grid) private var grid = GridStyle.thirds.rawValue
    @AppStorage(Keys.level) private var level = true
    @AppStorage(Keys.histogram) private var histogram = false
    @AppStorage(Keys.peaking) private var peaking = false
    @AppStorage(Keys.nightUI) private var nightUI = false
    @AppStorage(Keys.mirrorFront) private var mirrorFront = true
    @AppStorage(Keys.haptics) private var haptics = true

    var body: some View {
        NavigationView {
            Form {
                Section("Capture") {
                    Picker("Photo format", selection: $heif) {
                        Text("HEIF (smaller)").tag(true)
                        Text("JPEG (compatible)").tag(false)
                    }
                    Toggle("Keep original when a filter is used", isOn: $keepOriginal)
                    Toggle("Location tagging", isOn: $geotag)
                    Toggle("Mirror front camera", isOn: $mirrorFront)
                    Toggle("Haptic feedback", isOn: $haptics)
                }
                Section("Viewfinder") {
                    Picker("Grid", selection: $grid) {
                        ForEach(GridStyle.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    }
                    Toggle("Level indicator", isOn: $level)
                    Toggle("Live histogram", isOn: $histogram)
                    Toggle("Focus peaking", isOn: $peaking)
                    Toggle("Night vision (red) interface", isOn: $nightUI)
                }
                Section("Tips") {
                    Label("Stars, Trails and Long Exposure need a tripod.", systemImage: "camera.metering.unknown")
                    Label("Volume buttons trigger the shutter (iOS 17.2+).", systemImage: "speaker.wave.2")
                    Label("Hold the shutter in Photo mode for burst.", systemImage: "square.stack.3d.down.right")
                    Label("Tap the thumbnail to open the editor.", systemImage: "wand.and.stars")
                }
                Section {
                    HStack { Text("Lumina"); Spacer(); Text("1.0").foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
