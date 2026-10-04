import SwiftData
import SwiftUI

struct PlaylistEmptyState: View {
    let addMusicAction: () -> Void

    var body: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text("Empty Playlist")
                        .font(.headline)

                    Text("Choose songs from your music library to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Add Music", systemImage: "plus", action: addMusicAction)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

struct PlaylistAddMusicSection: View {
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                Label("Add Music", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AddMusicToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(InteractionCoordinator.self) private var interactions

    @State private var searchModel = LibrarySearchModel(storesHistory: false)
    @State private var selectedTrackIDs: Set<LibraryTrack.ID> = []
    @State private var pendingProposal: PlaylistAddProposal?
    @State private var isShowingDuplicateConfirmation = false
    @State private var isCommitting = false

    let playlist: AppPlaylist
    let destination: PlaylistGroup?

    init(playlist: AppPlaylist, destination: PlaylistGroup? = nil) {
        self.playlist = playlist
        self.destination = destination
    }

    var body: some View {
        NavigationStack {
            List {
                if SearchTextNormalizer.normalize(searchModel.query).isEmpty {
                    ForEach(mediaLibrary.tracks) { track in
                        AddMusicTrackSelectionRow(
                            track: track,
                            isSelected: selectedTrackIDs.contains(track.id),
                            isDisabled: isCommitting,
                            toggleAction: { toggleSelection(for: track) }
                        )
                    }
                } else {
                    AddMusicSearchSections(
                        searchModel: searchModel,
                        selectedTrackIDs: $selectedTrackIDs,
                        isDisabled: isCommitting
                    )
                }
            }
            .overlay {
                if mediaLibrary.tracks.isEmpty,
                   SearchTextNormalizer.normalize(searchModel.query).isEmpty {
                    ContentUnavailableView(
                        "No Music Available",
                        systemImage: "music.note",
                        description: Text("No songs were found in your music library.")
                    )
                }
            }
            .navigationTitle(destination?.name ?? String(localized: "Add Music"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: searchBinding,
                prompt: "Songs, artists, albums, and more"
            )
            .searchScopes(
                searchScopeBinding,
                activation: .onTextEntry
            ) {
                ForEach(LibrarySearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        prepareAdd()
                    } label: {
                        Text("Add \(selectedTrackIDs.count)")
                    }
                    .disabled(selectedTrackIDs.isEmpty)
                }
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
                    pendingProposal = nil
                }
            } message: {
                Text(duplicateDialogMessage)
            }
            .onChange(of: mediaLibrary.libraryRevision, initial: true) { _, _ in
                searchModel.rebuildIndex(
                    tracks: mediaLibrary.tracks,
                    collections: mediaLibrary.searchableCollections(),
                    playlists: [],
                    includeChauffle: false
                )
            }
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchModel.query },
            set: { searchModel.query = $0 }
        )
    }

    private var searchScopeBinding: Binding<LibrarySearchScope> {
        Binding(
            get: { searchModel.scope },
            set: { searchModel.scope = $0 }
        )
    }

    private var selectedTracks: [LibraryTrack] {
        mediaLibrary.tracks.filter { selectedTrackIDs.contains($0.id) }
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

    private func toggleSelection(for track: LibraryTrack) {
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
        interactions.announceSelectionChange()
    }

    private func prepareAdd() {
        let proposal = playlist.makeAddProposal(for: selectedTracks)

        if proposal.hasDuplicates {
            pendingProposal = proposal
            isShowingDuplicateConfirmation = true
        } else {
            commit(proposal.requestedTracks)
        }
    }

    private func commit(_ tracks: [LibraryTrack]) {
        guard !isCommitting else { return }
        isCommitting = true
        playlist.add(tracks, to: destination)
        do {
            try modelContext.save()
            let message = tracks.count == 1
                ? String(localized: "Added 1 song")
                : String(localized: "Added \(tracks.count) songs")
            interactions.showSuccess(message)
            pendingProposal = nil
            dismiss()
        } catch {
            modelContext.rollback()
            isCommitting = false
            interactions.showError(String(localized: "Couldn’t add songs"))
        }
    }
}

struct AddMusicSearchSections: View {
    let searchModel: LibrarySearchModel
    @Binding var selectedTrackIDs: Set<LibraryTrack.ID>
    let isDisabled: Bool

    var body: some View {
        if searchModel.isSearching && searchModel.results.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Searching")
                    Spacer()
                }
            }
        } else if searchModel.results.isEmpty {
            Section {
                ContentUnavailableView.search(text: searchModel.query)
                if let suggestion = searchModel.results.suggestion {
                    Button("Search for “\(suggestion)”") {
                        searchModel.query = suggestion
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            if !searchModel.results.topResults.isEmpty {
                AddMusicSearchResultSection(
                    title: "Top Results",
                    category: nil,
                    results: searchModel.results.topResults,
                    displayLimit: 3,
                    selectedTrackIDs: $selectedTrackIDs,
                    isDisabled: isDisabled
                )
            }

            ForEach(musicSearchCategories) { category in
                let results = searchModel.results.results(for: category)
                if !results.isEmpty {
                    AddMusicSearchResultSection(
                        title: category.title,
                        category: category,
                        results: results,
                        displayLimit: searchModel.scope == .all ? 5 : nil,
                        selectedTrackIDs: $selectedTrackIDs,
                        isDisabled: isDisabled
                    )
                }
            }
        }
    }

    private var musicSearchCategories: [LibrarySearchCategory] {
        [.song, .artist, .album, .composer, .genre, .musicPlaylist]
    }
}

struct AddMusicSearchResultSection: View {
    let title: LocalizedStringResource
    let category: LibrarySearchCategory?
    let results: [RankedLibrarySearchResult]
    let displayLimit: Int?
    @Binding var selectedTrackIDs: Set<LibraryTrack.ID>
    let isDisabled: Bool

    var body: some View {
        Section {
            ForEach(displayedResults) { result in
                AddMusicSearchResultCell(
                    result: result,
                    selectedTrackIDs: $selectedTrackIDs,
                    isDisabled: isDisabled
                )
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if let category, displayedResults.count < results.count {
                    NavigationLink("See All") {
                        AddMusicCategoryResultsView(
                            category: category,
                            results: results,
                            selectedTrackIDs: $selectedTrackIDs,
                            isDisabled: isDisabled
                        )
                    }
                    .textCase(nil)
                }
            }
        }
    }

    private var displayedResults: [RankedLibrarySearchResult] {
        guard let displayLimit else { return results }
        return Array(results.prefix(displayLimit))
    }
}

struct AddMusicCategoryResultsView: View {
    let category: LibrarySearchCategory
    let results: [RankedLibrarySearchResult]
    @Binding var selectedTrackIDs: Set<LibraryTrack.ID>
    let isDisabled: Bool

    var body: some View {
        List(results) { result in
            AddMusicSearchResultCell(
                result: result,
                selectedTrackIDs: $selectedTrackIDs,
                isDisabled: isDisabled
            )
        }
        .navigationTitle(category.title)
    }
}

struct AddMusicSearchResultCell: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(InteractionCoordinator.self) private var interactions

    let result: RankedLibrarySearchResult
    @Binding var selectedTrackIDs: Set<LibraryTrack.ID>
    let isDisabled: Bool

    var body: some View {
        VStack {
            switch result.document.source {
            case .track(let trackID):
                if let track = mediaLibrary.tracks.first(where: { $0.id == trackID }) {
                    AddMusicTrackSelectionRow(
                        track: track,
                        isSelected: selectedTrackIDs.contains(track.id),
                        isDisabled: isDisabled,
                        toggleAction: { toggle(track) }
                    )
                }
            case .collection:
                NavigationLink {
                    AddMusicGroupingSelectionView(
                        title: result.document.title,
                        tracks: mediaLibrary.tracks(withIDs: result.document.trackIDs),
                        selectedTrackIDs: $selectedTrackIDs
                    )
                } label: {
                    LibrarySearchResultLabel(document: result.document)
                }
            case .chauffeurPlaylist, .set:
                EmptyView()
            }
        }
    }

    private func toggle(_ track: LibraryTrack) {
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
        interactions.announceSelectionChange()
    }
}

struct AddMusicTrackSelectionRow: View {
    let track: LibraryTrack
    let isSelected: Bool
    let isDisabled: Bool
    let toggleAction: () -> Void

    var body: some View {
        Button(action: toggleAction) {
            TrackRow(track: track, isSelected: isSelected)
        }
        .buttonStyle(InteractiveRowButtonStyle())
        .disabled(isDisabled)
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear
        )
        .accessibilityHint(
            isSelected
                ? "Removes this song from the selection."
                : "Selects this song to add to the playlist."
        )
    }
}

struct AddMusicGroupingSelectionView: View {
    @Environment(InteractionCoordinator.self) private var interactions
    @State private var searchModel = TrackSearchModel()

    let title: String
    let tracks: [LibraryTrack]
    @Binding var selectedTrackIDs: Set<LibraryTrack.ID>

    var body: some View {
        List {
            Section {
                Button {
                    toggleAllSongs()
                } label: {
                    Label(
                        allSongsSelected ? "Deselect All" : selectAllLabel,
                        systemImage: allSongsSelected
                            ? "checkmark.circle.fill"
                            : "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Songs") {
                ForEach(searchModel.visibleTracks) { track in
                    AddMusicTrackSelectionRow(
                        track: track,
                        isSelected: selectedTrackIDs.contains(track.id),
                        isDisabled: false,
                        toggleAction: { toggle(track) }
                    )
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: searchBinding, prompt: "Search within this group")
        .onChange(of: tracks, initial: true) { _, newTracks in
            searchModel.updateTracks(newTracks)
        }
    }

    private var allSongsSelected: Bool {
        !tracks.isEmpty && tracks.allSatisfy { selectedTrackIDs.contains($0.id) }
    }

    private var selectAllLabel: String {
        tracks.count == 1
            ? String(localized: "Select 1 Song")
            : String(localized: "Select All \(tracks.count) Songs")
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchModel.searchText },
            set: { searchModel.searchText = $0 }
        )
    }

    private func toggleAllSongs() {
        if allSongsSelected {
            selectedTrackIDs.subtract(tracks.map(\.id))
        } else {
            selectedTrackIDs.formUnion(tracks.map(\.id))
        }
        interactions.announceSelectionChange()
    }

    private func toggle(_ track: LibraryTrack) {
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
        } else {
            selectedTrackIDs.insert(track.id)
        }
        interactions.announceSelectionChange()
    }
}
