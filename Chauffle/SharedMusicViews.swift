import Observation
import SwiftData
import SwiftUI
import UIKit

func localizedSongCount(_ count: Int) -> String {
    count == 1
        ? String(localized: "1 song")
        : String(localized: "\(count) songs")
}

@MainActor
@Observable
final class TrackSearchModel {
    var searchText = "" {
        didSet { updateVisibleTracks() }
    }

    private(set) var visibleTracks: [LibraryTrack] = []
    private var allTracks: [LibraryTrack] = []

    func updateTracks(_ tracks: [LibraryTrack]) {
        allTracks = tracks
        updateVisibleTracks()
    }

    private func updateVisibleTracks() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            visibleTracks = allTracks
        } else {
            visibleTracks = LibrarySearchEngine.rankedTracks(
                query: query,
                tracks: allTracks
            )
        }
    }
}

struct ArtworkView: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @State private var image: UIImage?

    let trackID: LibraryTrack.ID
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: trackID) {
            image = mediaLibrary.artwork(
                for: trackID,
                size: CGSize(width: size * 2, height: size * 2)
            )
        }
        .accessibilityHidden(true)
    }
}

struct TrackRow: View {
    let track: LibraryTrack
    var isSelected = false
    var isUnavailable = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(trackID: track.id)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isUnavailable {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Unavailable")
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            } else if track.isCloudItem {
                Image(systemName: "icloud")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cloud item")
            }
        }
        .contentShape(Rectangle())
    }
}

struct InteractiveRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.68 : 1)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

struct TrackBrowserView: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback
    @Environment(InteractionCoordinator.self) private var interactions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchModel = TrackSearchModel()
    @State private var isSelecting = false
    @State private var selectedTrackIDs: Set<LibraryTrack.ID> = []
    @State private var tracksForAdd: [LibraryTrack] = []
    @State private var isShowingAddSheet = false

    let title: String
    let tracks: [LibraryTrack]

    var body: some View {
        List(searchModel.visibleTracks) { track in
            HStack(spacing: 8) {
                Button {
                    handleTrackTap(track)
                } label: {
                    TrackRow(
                        track: track,
                        isSelected: selectedTrackIDs.contains(track.id)
                    )
                }
                .buttonStyle(InteractiveRowButtonStyle())
                .accessibilityHint(
                    isSelecting
                        ? "Selects or deselects this song."
                        : "Plays this song."
                )

                if !isSelecting {
                    Button(action: { showAddSheet(for: track) }) {
                        Image(systemName: "plus.circle")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(track.title) to a playlist")
                }
            }
            .listRowBackground(
                selectedTrackIDs.contains(track.id)
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !isSelecting {
                    Button(action: { showAddSheet(for: track) }) {
                        Label("Add", systemImage: "text.badge.plus")
                    }
                    .tint(.accentColor)
                }
            }
        }
        .overlay {
            if searchModel.visibleTracks.isEmpty {
                ContentUnavailableView.search(text: searchModel.searchText)
            }
        }
        .navigationTitle(title)
        .searchable(text: searchBinding, prompt: "Songs, artists, or albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting ? endSelection() : beginSelection()
                }
            }
        }
        .sheet(isPresented: $isShowingAddSheet, onDismiss: {
            interactions.isCommitting = false
        }) {
            AddTracksSheet(tracks: tracksForAdd) {
                if isSelecting {
                    endSelection()
                }
            }
        }
        .onChange(of: tracks, initial: true) { _, newTracks in
            searchModel.updateTracks(newTracks)
        }
        .onChange(of: interactions.addSelectionRequest) { _, _ in
            guard isSelecting, !selectedTrackIDs.isEmpty else { return }
            interactions.isCommitting = true
            tracksForAdd = tracks.filter { selectedTrackIDs.contains($0.id) }
            isShowingAddSheet = true
        }
        .onChange(of: interactions.cancelSelectionRequest) { _, _ in
            guard isSelecting else { return }
            endSelection()
        }
        .onDisappear {
            if isSelecting {
                interactions.endSelection()
            }
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchModel.searchText },
            set: { searchModel.searchText = $0 }
        )
    }

    private func handleTrackTap(_ track: LibraryTrack) {
        if isSelecting {
            withAnimation(reduceMotion ? nil : .snappy) {
                if selectedTrackIDs.contains(track.id) {
                    selectedTrackIDs.remove(track.id)
                } else {
                    selectedTrackIDs.insert(track.id)
                }
            }
            interactions.updateSelection(count: selectedTrackIDs.count)
        } else {
            playback.play(
                tracks: tracks,
                startingAt: track.id,
                mediaLibrary: mediaLibrary
            )
        }
    }

    private func beginSelection() {
        withAnimation(reduceMotion ? nil : .snappy) {
            isSelecting = true
        }
        interactions.beginSelection()
    }

    private func endSelection() {
        withAnimation(reduceMotion ? nil : .snappy) {
            isSelecting = false
            selectedTrackIDs.removeAll()
        }
        interactions.endSelection()
    }

    private func showAddSheet(for track: LibraryTrack) {
        tracksForAdd = [track]
        isShowingAddSheet = true
    }
}

struct AddTracksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppPlaylist.name) private var playlists: [AppPlaylist]
    @Environment(InteractionCoordinator.self) private var interactions

    @State private var pendingPlaylist: AppPlaylist?
    @State private var pendingProposal: PlaylistAddProposal?
    @State private var isShowingDuplicateConfirmation = false
    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var isCommitting = false

    let tracks: [LibraryTrack]
    var onCompletion: () -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newPlaylistName = ""
                    isCreatingPlaylist = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }

                ForEach(playlists) { playlist in
                    Button {
                        prepareAdd(to: playlist)
                    } label: {
                        PlaylistDestinationRow(
                            name: playlist.name,
                            songCount: playlist.orderedEntries.count
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isCommitting)
                }
            }
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("New Playlist", isPresented: $isCreatingPlaylist) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create") {
                    createPlaylist()
                }
                .disabled(
                    newPlaylistName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                duplicateDialogTitle,
                isPresented: $isShowingDuplicateConfirmation,
                titleVisibility: .visible
            ) {
                if let proposal = pendingProposal {
                    Button(
                        proposal.requestedTracks.count == 1
                            ? "Add Duplicate"
                            : "Add All"
                    ) {
                        commit(proposal.requestedTracks)
                    }

                    if proposal.requestedTracks.count > 1,
                       !proposal.newTracks.isEmpty {
                        Button("Add New Only") {
                            commit(proposal.newTracks)
                        }
                    }
                }

                Button("Cancel", role: .cancel) {
                    clearPendingAdd()
                }
            } message: {
                Text(duplicateDialogMessage)
            }
        }
    }

    private var duplicateDialogTitle: String {
        guard let proposal = pendingProposal else {
            return String(localized: "Duplicate Song")
        }

        return proposal.duplicateTracks.count == 1
            ? String(localized: "Duplicate Song")
            : String(localized: "Duplicate Songs")
    }

    private var duplicateDialogMessage: String {
        guard let proposal = pendingProposal else { return "" }

        if proposal.duplicateTracks.count == 1,
           let track = proposal.duplicateTracks.first {
            return String(
                localized: "“\(track.title)” is already in this playlist. Add it again?"
            )
        }

        return String(
            localized: "\(proposal.duplicateTracks.count) selected songs are already in this playlist."
        )
    }

    private func prepareAdd(to playlist: AppPlaylist) {
        let proposal = playlist.makeAddProposal(for: tracks)

        if proposal.hasDuplicates {
            pendingPlaylist = playlist
            pendingProposal = proposal
            isShowingDuplicateConfirmation = true
        } else {
            commit(tracks, to: playlist)
        }
    }

    private func commit(_ tracksToAdd: [LibraryTrack]) {
        guard let pendingPlaylist else { return }
        commit(tracksToAdd, to: pendingPlaylist)
    }

    private func commit(_ tracksToAdd: [LibraryTrack], to playlist: AppPlaylist) {
        guard !isCommitting else { return }
        isCommitting = true
        playlist.add(tracksToAdd)
        do {
            try modelContext.save()
            let message = tracksToAdd.count == 1
                ? String(localized: "Added 1 song")
                : String(localized: "Added \(tracksToAdd.count) songs")
            interactions.showSuccess(message)
            clearPendingAdd()
            onCompletion()
            dismiss()
        } catch {
            modelContext.rollback()
            isCommitting = false
            interactions.showError(String(localized: "Couldn’t add songs"))
        }
    }

    private func finishCreatingPlaylist() {
        let trackCount = tracks.count
        let message = trackCount == 1
            ? String(localized: "Created playlist with 1 song")
            : String(localized: "Created playlist with \(trackCount) songs")
        interactions.showSuccess(message)
        clearPendingAdd()
        onCompletion()
        dismiss()
    }

    private func clearPendingAdd() {
        pendingPlaylist = nil
        pendingProposal = nil
    }

    private func createPlaylist() {
        let name = newPlaylistName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let playlist = AppPlaylist(name: name)
        modelContext.insert(playlist)
        playlist.add(tracks)
        do {
            try modelContext.save()
            finishCreatingPlaylist()
        } catch {
            modelContext.rollback()
            interactions.showError(String(localized: "Couldn’t create playlist"))
        }
    }
}

struct PlaylistDestinationRow: View {
    let name: String
    let songCount: Int

    var body: some View {
        HStack {
            Image(systemName: "music.note.list")
                .foregroundStyle(.tint)

            VStack(alignment: .leading) {
                Text(name)
                Text(localizedSongCount(songCount))
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct MiniPlayerView: View {
    @Environment(PlaybackController.self) private var playback
    @State private var isShowingNowPlaying = false

    let track: LibraryTrack

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isShowingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(trackID: track.id, size: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                playback.togglePlayPause()
            } label: {
                Image(
                    systemName: playback.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                playback.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Next Track")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var playback

    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 12)

                if let track = playback.nowPlaying {
                    ArtworkView(trackID: track.id, size: 300)
                        .shadow(color: .black.opacity(0.2), radius: 24, y: 14)

                    NowPlayingMetadata(
                        title: track.title,
                        artist: track.artist,
                        album: track.albumTitle,
                        playlistName: playback.activePlaylistName,
                        setName: playback.activeSetName
                    )

                    VStack(spacing: 4) {
                        Slider(
                            value: scrubBinding,
                            in: 0...max(playback.duration, 1),
                            onEditingChanged: handleScrubbing
                        )
                        .accessibilityLabel("Playback Position")

                        HStack {
                            Text(formattedTime(isScrubbing ? scrubPosition : playback.elapsedTime))
                            Spacer()
                            Text("−\(formattedTime(max(playback.duration - (isScrubbing ? scrubPosition : playback.elapsedTime), 0)))")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    NowPlayingTransportControls()

                    if let errorMessage = playback.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "music.note",
                        description: Text("Choose a song or playlist to begin playback.")
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 28)
            .background(
                LinearGradient(
                    colors: [.accentColor.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "chevron.down") {
                        dismiss()
                    }
                }
            }
            .onChange(of: playback.elapsedTime, initial: true) { _, newValue in
                if !isScrubbing {
                    scrubPosition = newValue
                }
            }
        }
    }

    private var scrubBinding: Binding<TimeInterval> {
        Binding(
            get: { isScrubbing ? scrubPosition : playback.elapsedTime },
            set: { scrubPosition = $0 }
        )
    }

    private func handleScrubbing(_ editing: Bool) {
        isScrubbing = editing
        if !editing {
            playback.seek(to: scrubPosition)
        }
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct NowPlayingMetadata: View {
    let title: String
    let artist: String
    let album: String
    let playlistName: String?
    let setName: String?

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(artist)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(album)
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            if let playlistName {
                if let setName {
                    Label("\(playlistName) • \(setName)", systemImage: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(playlistName, systemImage: "music.note.list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct NowPlayingTransportControls: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        HStack(spacing: 54) {
            Button {
                playback.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Previous Track")

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                playback.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Next Track")
        }
        .buttonStyle(.plain)
    }
}
