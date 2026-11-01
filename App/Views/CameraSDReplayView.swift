import SwiftUI
import HorizonCore

struct CameraSDReplayView: View {
    let api: HorizonAPI
    let camera: String
    var body: some View {
        ContentUnavailableView(String(localized: "viewer.recordedTitle", defaultValue: "Recorded viewing requires a server upgrade"),
            systemImage: "sdcard", description: Text(ViewingMessage.recorded))
            .navigationTitle("Camera-SD replay")
            .horizonScreen()
    }
}
