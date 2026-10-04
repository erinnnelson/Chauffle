import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InteractionCoordinator.self) private var interactions
    @Query(sort: \AppPlaylist.createdAt, order: .reverse)
    private var playlists: [AppPlaylist]

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistsPendingDeletion: [AppPlaylist] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        PlaylistDestinationRow(
                            name: playlist.name,
                            songCount: playlist.orderedEntries.count
                        )
                    }
                }
                .onDelete(perform: deletePlaylists)
            }
            .overlay {
                if playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No Playlists", systemImage: "music.note.list")
                    } description: {
                        Text("Create a playlist, then add songs from your library.")
                    } actions: {
                        Button("New Playlist") {
                            beginCreatingPlaylist()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        beginCreatingPlaylist()
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $isCreatingPlaylist) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create", action: createPlaylist)
                    .disabled(trimmedPlaylistName.isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                playlistsPendingDeletion.count == 1
                    ? "Delete Playlist?"
                    : "Delete Playlists?",
                isPresented: deletePlaylistConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    confirmDeletePlaylists()
                }
                Button("Cancel", role: .cancel) {
                    playlistsPendingDeletion = []
                }
            } message: {
                Text("This removes the playlist structure but does not delete music from your library.")
            }
        }
    }

    private var trimmedPlaylistName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deletePlaylistConfirmationBinding: Binding<Bool> {
        Binding(
            get: { !playlistsPendingDeletion.isEmpty },
            set: { if !$0 { playlistsPendingDeletion = [] } }
        )
    }

    private func beginCreatingPlaylist() {
        newPlaylistName = ""
        isCreatingPlaylist = true
    }

    private func createPlaylist() {
        guard !trimmedPlaylistName.isEmpty else { return }
        modelContext.insert(AppPlaylist(name: trimmedPlaylistName))
        do {
            try modelContext.save()
            interactions.showSuccess(String(localized: "Created playlist"))
        } catch {
            modelContext.rollback()
            interactions.showError(String(localized: "Couldn’t create playlist"))
        }
    }

    private func deletePlaylists(at offsets: IndexSet) {
        playlistsPendingDeletion = offsets.map { playlists[$0] }
    }

    private func confirmDeletePlaylists() {
        let pending = playlistsPendingDeletion
        for playlist in pending {
            modelContext.delete(playlist)
        }
        do {
            try modelContext.save()
            playlistsPendingDeletion = []
            let message = pending.count == 1
                ? String(localized: "Deleted playlist")
                : String(localized: "Deleted \(pending.count) playlists")
            interactions.showSuccess(message)
        } catch {
            modelContext.rollback()
            playlistsPendingDeletion = []
            interactions.showError(String(localized: "Couldn’t delete playlist"))
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback
    @Environment(InteractionCoordinator.self) private var interactions

    let playlist: AppPlaylist

    @State private var isRenamingPlaylist = false
    @State private var isShowingMusicPicker = false
    @State private var isCreatingSet = false
    @State private var editedName = ""
    @State private var newSetName = ""
    @State private var setPendingDeletion: PlaylistGroup?

    var body: some View {
        List {
            PlaylistPlaybackHeader(
                songCount: playlist.orderedEntries.count,
                canPlay: hasPlayableEntries,
                orderMode: orderModeBinding,
                isLooping: loopBinding,
                playAction: playAll
            )

            if playlist.orderedContent.isEmpty {
                PlaylistEmptyState(addMusicAction: showMusicPicker)
            } else {
                Section("Playlist Order") {
                    ForEach(playlist.orderedContent) { item in
                        PlaylistContentRow(
                            item: item,
                            playlist: playlist,
                            deleteSetAction: { setPendingDeletion = $0 }
                        )
                    }
                    .onMove(perform: moveContent)
                    .onDelete(perform: deleteContent)
                }

                PlaylistAddMusicSection(action: showMusicPicker)
            }

            Section {
                Button {
                    beginCreatingSet()
                } label: {
                    Label("New Set", systemImage: "rectangle.stack.badge.plus")
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: showMusicPicker) {
                    Label("Add Music", systemImage: "plus")
                }

                Menu {
                    Button {
                        beginCreatingSet()
                    } label: {
                        Label("New Set", systemImage: "rectangle.stack.badge.plus")
                    }

                    Button {
                        editedName = playlist.name
                        isRenamingPlaylist = true
                    } label: {
                        Label("Rename Playlist", systemImage: "pencil")
                    }

                    if !playlist.orderedContent.isEmpty {
                        EditButton()
                    }
                } label: {
                    Label("Playlist Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingMusicPicker) {
            AddMusicToPlaylistSheet(playlist: playlist)
        }
        .alert("Rename Playlist", isPresented: $isRenamingPlaylist) {
            TextField("Playlist Name", text: $editedName)
            Button("Save", action: renamePlaylist)
                .disabled(trimmedEditedName.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Set", isPresented: $isCreatingSet) {
            TextField("Set Name", text: $newSetName)
            Button("Create", action: createSet)
                .disabled(trimmedSetName.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets play as a single block inside the parent playlist.")
        }
        .confirmationDialog(
            "Delete Set?",
            isPresented: deleteSetConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Keep Songs in Playlist") {
                deletePendingSet(keepingSongs: true)
            }
            Button("Delete Set and Songs", role: .destructive) {
                deletePendingSet(keepingSongs: false)
            }
            Button("Cancel", role: .cancel) {
                setPendingDeletion = nil
            }
        } message: {
            Text("Choose whether the songs should remain in the parent playlist.")
        }
    }

    private var hasPlayableEntries: Bool {
        playlist.orderedEntries.contains { mediaLibrary.resolvedTrack(for: $0) != nil }
    }

    private var trimmedEditedName: String {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSetName: String {
        newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var orderModeBinding: Binding<PlaylistOrderMode> {
        Binding(
            get: { playlist.orderMode },
            set: { newValue in
                playlist.orderMode = newValue
                savePlaylistChange()
            }
        )
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { playlist.isLooping },
            set: { newValue in
                playlist.isLooping = newValue
                playlist.updatedAt = Date()
                savePlaylistChange()
            }
        )
    }

    private var deleteSetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { setPendingDeletion != nil },
            set: { if !$0 { setPendingDeletion = nil } }
        )
    }

    private func playAll() {
        playback.play(playlist: playlist, startingAt: nil, mediaLibrary: mediaLibrary)
    }

    private func moveContent(from source: IndexSet, to destination: Int) {
        playlist.moveTopLevel(from: source, to: destination)
        savePlaylistChange()
    }

    private func deleteContent(at offsets: IndexSet) {
        let content = playlist.orderedContent
        var removedSnapshots: [RemovedPlaylistEntrySnapshot] = []
        for index in offsets {
            switch content[index] {
            case .song(let entry):
                if let snapshot = playlist.remove(entry) {
                    removedSnapshots.append(snapshot)
                    modelContext.delete(entry)
                }
            case .set(let set):
                setPendingDeletion = set
            }
        }
        guard !removedSnapshots.isEmpty else { return }
        guard savePlaylistChange() else { return }
        showRemovalUndo(for: removedSnapshots)
    }

    private func beginCreatingSet() {
        newSetName = "Set \(playlist.sets.count + 1)"
        isCreatingSet = true
    }

    private func createSet() {
        guard !trimmedSetName.isEmpty else { return }
        playlist.createSet(named: trimmedSetName)
        if savePlaylistChange() {
            interactions.showSuccess(String(localized: "Created Set"))
        }
    }

    private func deletePendingSet(keepingSongs: Bool) {
        guard let set = setPendingDeletion else { return }
        playlist.deleteSet(set, keepingSongs: keepingSongs)
        modelContext.delete(set)
        setPendingDeletion = nil
        if savePlaylistChange() {
            interactions.showSuccess(String(localized: "Deleted Set"))
        }
    }

    private func showMusicPicker() {
        isShowingMusicPicker = true
    }

    private func renamePlaylist() {
        guard !trimmedEditedName.isEmpty else { return }
        playlist.name = trimmedEditedName
        playlist.updatedAt = Date()
        if savePlaylistChange() {
            interactions.showSuccess(String(localized: "Renamed playlist"))
        }
    }

    @discardableResult
    private func savePlaylistChange() -> Bool {
        do {
            try modelContext.save()
            playback.playlistDidChange(playlist)
            return true
        } catch {
            modelContext.rollback()
            interactions.showError(String(localized: "Couldn’t save playlist changes"))
            return false
        }
    }

    private func showRemovalUndo(for snapshots: [RemovedPlaylistEntrySnapshot]) {
        let message = snapshots.count == 1
            ? String(localized: "Removed 1 song")
            : String(localized: "Removed \(snapshots.count) songs")
        interactions.showRemoval(message) {
            let restoredEntries = snapshots
                .sorted { $0.position < $1.position }
                .compactMap { playlist.restore($0) }
            restoredEntries.forEach(modelContext.insert)
            do {
                try modelContext.save()
                playback.playlistDidChange(playlist)
                interactions.showSuccess(String(localized: "Restored songs"))
            } catch {
                modelContext.rollback()
                interactions.showError(String(localized: "Couldn’t restore songs"))
            }
        }
    }
}

struct PlaylistPlaybackHeader: View {
    let songCount: Int
    let canPlay: Bool
    @Binding var orderMode: PlaylistOrderMode
    @Binding var isLooping: Bool
    let playAction: () -> Void

    var body: some View {
        Section {
            Picker("Playlist Order", selection: $orderMode) {
                Label("In Order", systemImage: "list.number")
                    .tag(PlaylistOrderMode.inOrder)
                Label("Random", systemImage: "shuffle")
                    .tag(PlaylistOrderMode.random)
            }
            .pickerStyle(.segmented)

            Toggle("Loop Playlist", systemImage: "repeat", isOn: $isLooping)

            Button(action: playAction) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPlay)
        } header: {
            Text(localizedSongCount(songCount))
        }
    }
}

struct PlaylistContentRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback

    let item: PlaylistContentItem
    let playlist: AppPlaylist
    let deleteSetAction: (PlaylistGroup) -> Void

    var body: some View {
        switch item {
        case .song(let entry):
            PlaylistSongContentRow(entry: entry, playlist: playlist)
        case .set(let set):
            NavigationLink {
                SetDetailView(playlist: playlist, set: set)
            } label: {
                SetSummaryRow(set: set)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", role: .destructive) {
                    deleteSetAction(set)
                }
            }
        }
    }
}

struct PlaylistSongContentRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback
    @Environment(InteractionCoordinator.self) private var interactions

    @State private var isChoosingSet = false

    let entry: PlaylistEntry
    let playlist: AppPlaylist

    var body: some View {
        Button {
            playback.play(
                playlist: playlist,
                startingAt: entry.id,
                mediaLibrary: mediaLibrary
            )
        } label: {
            PlaylistEntryRow(
                entry: entry,
                resolvedTrack: mediaLibrary.resolvedTrack(for: entry)
            )
        }
        .buttonStyle(InteractiveRowButtonStyle())
        .accessibilityHint("Plays this song.")
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                removeEntry()
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !playlist.sets.isEmpty {
                Button("Move", systemImage: "rectangle.stack.badge.plus") {
                    isChoosingSet = true
                }
                .tint(.accentColor)
            }
        }
        .contextMenu {
            if !playlist.sets.isEmpty {
                Menu("Move to Set") {
                    ForEach(playlist.sets) { set in
                        Button(set.name) {
                            move(to: set)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Move to Set",
            isPresented: $isChoosingSet,
            titleVisibility: .visible
        ) {
            ForEach(playlist.sets) { set in
                Button(set.name) {
                    move(to: set)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func move(to set: PlaylistGroup) {
        playlist.move(entry, to: set)
        if saveChange() {
            interactions.showSuccess(String(localized: "Moved to \(set.name)"))
        }
    }

    private func removeEntry() {
        guard let snapshot = playlist.remove(entry) else { return }
        modelContext.delete(entry)
        guard saveChange() else { return }

        interactions.showRemoval(String(localized: "Removed \(snapshot.title)")) {
            guard let restoredEntry = playlist.restore(snapshot) else {
                interactions.showError(String(localized: "Couldn’t restore song"))
                return
            }
            modelContext.insert(restoredEntry)
            if saveChange() {
                interactions.showSuccess(String(localized: "Restored \(snapshot.title)"))
            }
        }
    }

    @discardableResult
    private func saveChange() -> Bool {
        do {
            try modelContext.save()
            playback.playlistDidChange(playlist)
            return true
        } catch {
            modelContext.rollback()
            interactions.showError(String(localized: "Couldn’t save playlist changes"))
            return false
        }
    }
}

struct SetSummaryRow: View {
    let set: PlaylistGroup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(set.name)
                    .font(.headline)
                Text(setRuleDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setRuleDescription: String {
        let selection: String
        switch set.selectionMode {
        case .all: selection = String(localized: "All songs")
        case .one: selection = String(localized: "1 song")
        case .count:
            selection = localizedSongCount(set.selectionCount ?? 1)
        }
        let order = set.orderMode == .random
            ? String(localized: "Random")
            : String(localized: "In Order")
        return String(localized: "\(selection) • \(order)")
    }
}

struct SetDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback
    @Environment(InteractionCoordinator.self) private var interactions

    let playlist: AppPlaylist
    let set: PlaylistGroup

    @State private var isShowingMusicPicker = false
    @State private var isRenaming = false
    @State private var editedName = ""

    var body: some View {
        List {
            Section("Playback Rule") {
                Picker("Songs", selection: selectionModeBinding) {
                    Text("All").tag(PlaylistSelectionMode.all)
                    Text("One").tag(PlaylistSelectionMode.one)
                    Text("Count").tag(PlaylistSelectionMode.count)
                }

                if set.selectionMode == .count {
                    Stepper(value: selectionCountBinding, in: 1...max(set.entries.count, 1)) {
                        SetSelectionCountLabel(count: set.selectionCount ?? 1)
                    }
                }

                Picker("Order", selection: orderModeBinding) {
                    Text("In Order").tag(PlaylistOrderMode.inOrder)
                    Text("Random").tag(PlaylistOrderMode.random)
                }
            }

            Section("Songs") {
                if set.orderedEntries.isEmpty {
                    ContentUnavailableView(
                        "Empty Set",
                        systemImage: "rectangle.stack",
                        description: Text("Add music to include this Set in playback.")
                    )
                } else {
                    ForEach(set.orderedEntries) { entry in
                        SetSongContentRow(entry: entry, playlist: playlist)
                    }
                    .onMove(perform: moveEntries)
                    .onDelete(perform: deleteEntries)
                }

                Button {
                    isShowingMusicPicker = true
                } label: {
                    Label("Add Music", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle(set.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isShowingMusicPicker = true
                } label: {
                    Label("Add Music", systemImage: "plus")
                }

                Button {
                    editedName = set.name
                    isRenaming = true
                } label: {
                    Label("Rename Set", systemImage: "pencil")
                }

                if !set.entries.isEmpty {
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $isShowingMusicPicker) {
            AddMusicToPlaylistSheet(playlist: playlist, destination: set)
        }
        .alert("Rename Set", isPresented: $isRenaming) {
            TextField("Set Name", text: $editedName)
            Button("Save", action: renameSet)
                .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var selectionModeBinding: Binding<PlaylistSelectionMode> {
        Binding(
            get: { set.selectionMode },
            set: { mode in
                set.selectionMode = mode
                if mode == .count, set.selectionCount == nil {
                    set.selectionCount = min(2, max(set.entries.count, 1))
                }
                saveChange()
            }
        )
    }

    private var orderModeBinding: Binding<PlaylistOrderMode> {
        Binding(
            get: { set.orderMode },
            set: { set.orderMode = $0; saveChange() }
        )
    }

    private var selectionCountBinding: Binding<Int> {
        Binding(
            get: { min(max(set.selectionCount ?? 1, 1), max(set.entries.count, 1)) },
            set: { set.selectionCount = $0; saveChange() }
        )
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        var entries = set.orderedEntries
        entries.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in entries.enumerated() {
            entry.position = index
        }
        saveChange()
    }

    private func deleteEntries(at offsets: IndexSet) {
        let entries = set.orderedEntries
        var snapshots: [RemovedPlaylistEntrySnapshot] = []
        for index in offsets {
            let entry = entries[index]
            if let snapshot = playlist.remove(entry) {
                snapshots.append(snapshot)
                modelContext.delete(entry)
            }
        }
        guard !snapshots.isEmpty, saveChange() else { return }
        let message = snapshots.count == 1
            ? String(localized: "Removed 1 song")
            : String(localized: "Removed \(snapshots.count) songs")
        interactions.showRemoval(message) {
            let restoredEntries = snapshots
                .sorted { $0.position < $1.position }
                .compactMap { playlist.restore($0) }
            restoredEntries.forEach(modelContext.insert)
            if saveChange() {
                interactions.showSuccess(String(localized: "Restored songs"))
            }
        }
    }

    private func renameSet() {
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        set.name = name
        if saveChange() {
            interactions.showSuccess(String(localized: "Renamed Set"))
        }
    }

    @discardableResult
    private func saveChange() -> Bool {
        playlist.updatedAt = Date()
        do {
            try modelContext.save()
            playback.playlistDidChange(playlist)
            return true
        } catch {
            modelContext.rollback()
            interactions.showError(String(localized: "Couldn’t save Set changes"))
            return false
        }
    }
}

struct SetSongContentRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback
    @Environment(InteractionCoordinator.self) private var interactions

    let entry: PlaylistEntry
    let playlist: AppPlaylist

    var body: some View {
        Button {
            playback.play(
                playlist: playlist,
                startingAt: entry.id,
                mediaLibrary: mediaLibrary
            )
        } label: {
            PlaylistEntryRow(
                entry: entry,
                resolvedTrack: mediaLibrary.resolvedTrack(for: entry)
            )
        }
        .buttonStyle(InteractiveRowButtonStyle())
        .accessibilityHint("Plays this song.")
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                removeEntry()
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("Move", systemImage: "arrow.up.to.line") {
                moveToParent()
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button("Move to Parent Playlist") {
                moveToParent()
            }
        }
    }

    private func moveToParent() {
        playlist.move(entry, to: playlist.defaultGroup())
        if saveChange() {
            interactions.showSuccess(String(localized: "Moved to parent playlist"))
        }
    }

    private func removeEntry() {
        guard let snapshot = playlist.remove(entry) else { return }
        modelContext.delete(entry)
        guard saveChange() else { return }

        interactions.showRemoval(String(localized: "Removed \(snapshot.title)")) {
            guard let restoredEntry = playlist.restore(snapshot) else {
                interactions.showError(String(localized: "Couldn’t restore song"))
                return
            }
            modelContext.insert(restoredEntry)
            if saveChange() {
                interactions.showSuccess(String(localized: "Restored \(snapshot.title)"))
            }
        }
    }

    @discardableResult
    private func saveChange() -> Bool {
        playlist.updatedAt = Date()
        do {
            try modelContext.save()
            playback.playlistDidChange(playlist)
            return true
        } catch {
            modelContext.rollback()
            interactions.showError(String(localized: "Couldn’t save Set changes"))
            return false
        }
    }
}

struct SetSelectionCountLabel: View {
    let count: Int

    var body: some View {
        if count == 1 {
            Text("Play 1 song")
        } else {
            Text(
                "Play \(count) songs",
                comment: "Number of songs a Set selects during playback."
            )
        }
    }
}

struct PlaylistEntryRow: View {
    let entry: PlaylistEntry
    let resolvedTrack: LibraryTrack?

    var body: some View {
        let track = resolvedTrack ?? LibraryTrack(entry: entry)

        TrackRow(track: track, isUnavailable: resolvedTrack == nil)
            .accessibilityHint(
                resolvedTrack == nil
                    ? "This song is no longer available in the music library."
                    : "Plays this playlist starting with this song."
            )
    }
}
