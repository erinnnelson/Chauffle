import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(InteractionCoordinator.self) private var interactions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView {
            Tab("Library", systemImage: "music.note.house") {
                LibraryRootView()
            }

            Tab("Playlists", systemImage: "music.note.list") {
                PlaylistsView()
            }
        }
        .tabViewBottomAccessory(
            isEnabled: interactions.selectionCount != nil || playback.nowPlaying != nil
        ) {
            if let selectionCount = interactions.selectionCount {
                SelectionAccessoryView(selectionCount: selectionCount)
            } else if let track = playback.nowPlaying {
                MiniPlayerView(track: track)
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = interactions.banner {
                InteractionBannerView(banner: banner)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 124)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: interactions.banner)
        .sensoryFeedback(trigger: interactions.feedbackEvent) { _, event in
            guard let event else { return nil }
            switch event.kind {
            case .selection: return SensoryFeedback.selection
            case .success: return SensoryFeedback.success
            case .warning: return SensoryFeedback.warning
            case .error: return SensoryFeedback.error
            }
        }
    }
}

struct SelectionAccessoryView: View {
    @Environment(InteractionCoordinator.self) private var interactions

    let selectionCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                interactions.requestCancelSelection()
            }

            Spacer()

            Text(
                "\(selectionCount) selected",
                comment: "Number of selected songs in the multi-selection bar."
            )
            .font(.subheadline.weight(.semibold))

            Spacer()

            Button("Add") {
                interactions.requestAddSelection()
            }
            .fontWeight(.semibold)
            .disabled(selectionCount == 0 || interactions.isCommitting)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

struct InteractionBannerView: View {
    @Environment(InteractionCoordinator.self) private var interactions

    let banner: InteractionBanner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.systemImage)
                .foregroundStyle(
                    banner.offersUndo ? Color.orange : Color.accentColor
                )
                .accessibilityHidden(true)

            Text(banner.message)
                .font(.subheadline)
                .lineLimit(2)

            Spacer(minLength: 8)

            if banner.offersUndo {
                Button("Undo") {
                    interactions.performUndo()
                }
                .fontWeight(.semibold)
            }

            Button {
                interactions.dismissBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

#Preview {
    ContentView()
        .environment(MediaLibraryService())
        .environment(PlaybackController())
        .environment(InteractionCoordinator())
        .modelContainer(
            for: [
                AppPlaylist.self,
                PlaylistGroup.self,
                PlaylistEntry.self
            ],
            inMemory: true
        )
}
