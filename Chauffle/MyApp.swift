import SwiftData
import SwiftUI

@main
@MainActor
struct MyApp: App {
    @State private var mediaLibrary = MediaLibraryService()
    @State private var playback = PlaybackController()
    @State private var interactions = InteractionCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(mediaLibrary)
                .environment(playback)
                .environment(interactions)
        }
        .modelContainer(
            for: [
                AppPlaylist.self,
                PlaylistGroup.self,
                PlaylistEntry.self
            ]
        )
    }
}
