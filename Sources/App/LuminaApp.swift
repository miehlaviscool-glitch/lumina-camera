import SwiftUI

@main
struct LuminaApp: App {
    init() { AppDefaults.register() }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
