import SwiftData
import SwiftUI
import UIKit

struct LibraryRootView: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary

    var body: some View {
        NavigationStack {
            switch mediaLibrary.accessState {
            case .notDetermined:
                LibraryPermissionView(
                    title: "Connect Your Music Library",
                    message: "Choose music from your synced, downloaded, purchased, and cloud library.",
                    buttonTitle: "Continue",
                    action: {
                        Task {
                            await mediaLibrary.requestAccess()
                        }
                    }
                )
            case .denied, .restricted:
                LibraryDeniedView()
            case .authorized:
                LibraryContentView()
            }
        }
    }
}

struct LibraryPermissionView: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let buttonTitle: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "music.note.house")
        } description: {
            Text(message)
        } actions: {
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Library")
    }
}

struct LibraryDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Music Access Is Off", systemImage: "lock")
        } description: {
            Text("Allow music-library access in Settings to browse and play your music.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Library")
    }
}

struct LibraryContentView: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Query(sort: \AppPlaylist.createdAt, order: .reverse)
    private var playlists: [AppPlaylist]

    @State private var searchModel = LibrarySearchModel()
    @State private var isSearchPresented = false

    var body: some View {
        List {
            if SearchTextNormalizer.normalize(searchModel.query).isEmpty {
                if isSearchPresented && !searchModel.recentQueries.isEmpty {
                    RecentSearchesSection(searchModel: searchModel)
                }
                LibraryBrowseContent()
            } else {
                LibrarySearchSections(
                    searchModel: searchModel,
                    playlists: playlists
                )
            }
        }
        .overlay {
            if mediaLibrary.isLoading {
                ProgressView("Loading Library")
            }
        }
        .navigationTitle("Library")
        .searchable(
            text: searchBinding,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
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
        .onSubmit(of: .search) {
            searchModel.recordCurrentQuery()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    mediaLibrary.loadLibrary()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onChange(of: mediaLibrary.libraryRevision, initial: true) { _, _ in
            rebuildSearchIndex()
        }
        .onChange(of: playlistSearchRevision, initial: true) { _, _ in
            rebuildSearchIndex()
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

    private var playlistSearchRevision: [PlaylistSearchRevision] {
        playlists.map { playlist in
            PlaylistSearchRevision(
                id: playlist.id,
                updatedAt: playlist.updatedAt,
                setIDs: playlist.sets.map(\.id)
            )
        }
    }

    private func rebuildSearchIndex() {
        searchModel.rebuildIndex(
            tracks: mediaLibrary.tracks,
            collections: mediaLibrary.searchableCollections(),
            playlists: playlists,
            includeChauffle: true
        )
    }
}

struct PlaylistSearchRevision: Equatable {
    let id: UUID
    let updatedAt: Date
    let setIDs: [UUID]
}

struct LibraryBrowseContent: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary

    var body: some View {
        if !mediaLibrary.isLoading && mediaLibrary.tracks.isEmpty {
            Section {
                LibraryEmptyStateRow()
            }
        }

        NavigationLink {
            TrackBrowserView(
                title: String(localized: "Songs"),
                tracks: mediaLibrary.tracks
            )
        } label: {
            Label("Songs", systemImage: "music.note")
        }

        ForEach(LibraryCollectionKind.allCases) { kind in
            NavigationLink {
                CollectionListView(kind: kind)
            } label: {
                Label(kind.title, systemImage: kind.systemImage)
            }
        }
    }
}

struct RecentSearchesSection: View {
    let searchModel: LibrarySearchModel

    var body: some View {
        Section {
            ForEach(searchModel.recentQueries, id: \.self) { query in
                Button {
                    searchModel.useRecentQuery(query)
                } label: {
                    Label(query, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        searchModel.removeRecentQuery(query)
                    }
                }
            }
        } header: {
            HStack {
                Text("Recent Searches")
                Spacer()
                Button("Clear All") {
                    searchModel.clearRecentQueries()
                }
                .textCase(nil)
            }
        }
    }
}

struct LibrarySearchSections: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary

    let searchModel: LibrarySearchModel
    let playlists: [AppPlaylist]

    var body: some View {
        let songQueue: [LibraryTrack] = searchModel.results.results(for: .song).compactMap { result -> LibraryTrack? in
            guard case .track(let id) = result.document.source else { return nil }
            return mediaLibrary.tracks.first { $0.id == id }
        }

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
                LibrarySearchResultSection(
                    title: "Top Results",
                    category: nil,
                    results: searchModel.results.topResults,
                    displayLimit: 3,
                    songQueue: songQueue,
                    playlists: playlists,
                    searchModel: searchModel
                )
            }

            ForEach(LibrarySearchCategory.allCases) { category in
                let results = searchModel.results.results(for: category)
                if !results.isEmpty {
                    LibrarySearchResultSection(
                        title: category.title,
                        category: category,
                        results: results,
                        displayLimit: searchModel.scope == .all ? 5 : nil,
                        songQueue: songQueue,
                        playlists: playlists,
                        searchModel: searchModel
                    )
                }
            }
        }
    }
}

struct LibrarySearchResultSection: View {
    let title: LocalizedStringResource
    let category: LibrarySearchCategory?
    let results: [RankedLibrarySearchResult]
    let displayLimit: Int?
    let songQueue: [LibraryTrack]
    let playlists: [AppPlaylist]
    let searchModel: LibrarySearchModel

    var body: some View {
        Section {
            ForEach(displayedResults) { result in
                LibrarySearchResultCell(
                    result: result,
                    songQueue: songQueue,
                    playlists: playlists,
                    searchModel: searchModel
                )
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if let category, displayedResults.count < results.count {
                    NavigationLink("See All") {
                        SearchCategoryResultsView(
                            category: category,
                            results: results,
                            songQueue: songQueue,
                            playlists: playlists,
                            searchModel: searchModel
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

struct SearchCategoryResultsView: View {
    let category: LibrarySearchCategory
    let results: [RankedLibrarySearchResult]
    let songQueue: [LibraryTrack]
    let playlists: [AppPlaylist]
    let searchModel: LibrarySearchModel

    var body: some View {
        List(results) { result in
            LibrarySearchResultCell(
                result: result,
                songQueue: songQueue,
                playlists: playlists,
                searchModel: searchModel
            )
        }
        .navigationTitle(category.title)
    }
}

struct LibrarySearchResultCell: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @Environment(PlaybackController.self) private var playback

    let result: RankedLibrarySearchResult
    let songQueue: [LibraryTrack]
    let playlists: [AppPlaylist]
    let searchModel: LibrarySearchModel

    var body: some View {
        VStack {
            switch result.document.source {
            case .track(let trackID):
                if let track = mediaLibrary.tracks.first(where: { $0.id == trackID }) {
                    Button {
                        searchModel.recordCurrentQuery()
                        playback.play(
                            tracks: songQueue,
                            startingAt: track.id,
                            mediaLibrary: mediaLibrary
                        )
                    } label: {
                        LibrarySearchResultLabel(document: result.document)
                    }
                    .buttonStyle(InteractiveRowButtonStyle())
                    .accessibilityHint("Plays this song and the remaining search results.")
                }
            case .collection:
                NavigationLink {
                    TrackBrowserView(
                        title: result.document.title,
                        tracks: mediaLibrary.tracks(withIDs: result.document.trackIDs)
                    )
                } label: {
                    LibrarySearchResultLabel(document: result.document)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    searchModel.recordCurrentQuery()
                })
            case .chauffeurPlaylist(let playlistID):
                if let playlist = playlists.first(where: { $0.id == playlistID }) {
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        LibrarySearchResultLabel(document: result.document)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        searchModel.recordCurrentQuery()
                    })
                }
            case .set(let playlistID, let setID):
                if let playlist = playlists.first(where: { $0.id == playlistID }),
                   let set = playlist.sets.first(where: { $0.id == setID }) {
                    NavigationLink {
                        SetDetailView(playlist: playlist, set: set)
                    } label: {
                        LibrarySearchResultLabel(document: result.document)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        searchModel.recordCurrentQuery()
                    })
                }
            }
        }
    }
}

struct LibrarySearchResultLabel: View {
    let document: LibrarySearchDocument

    var body: some View {
        HStack(spacing: 12) {
            if case .track(let trackID) = document.source {
                ArtworkView(trackID: trackID)
            } else {
                Image(systemName: document.category.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(document.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct LibraryEmptyStateRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("No Music Found")
                    .font(.headline)

                Text("Add music to the Music app, then refresh your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
@Observable
final class CollectionSearchModel {
    var searchText = "" {
        didSet { updateVisibleCollections() }
    }

    private(set) var visibleCollections: [LibraryCollection] = []
    private var allCollections: [LibraryCollection] = []

    func updateCollections(_ collections: [LibraryCollection]) {
        allCollections = collections
        updateVisibleCollections()
    }

    private func updateVisibleCollections() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            visibleCollections = allCollections
        } else {
            visibleCollections = allCollections.filter {
                $0.title.localizedCaseInsensitiveContains(query)
            }
        }
    }
}

struct CollectionListView: View {
    @Environment(MediaLibraryService.self) private var mediaLibrary
    @State private var searchModel = CollectionSearchModel()

    let kind: LibraryCollectionKind

    var body: some View {
        List(searchModel.visibleCollections) { collection in
            NavigationLink {
                TrackBrowserView(
                    title: collection.title,
                    tracks: mediaLibrary.tracks(withIDs: collection.trackIDs)
                )
            } label: {
                CollectionRow(
                    title: collection.title,
                    subtitle: collection.subtitle,
                    systemImage: kind.systemImage
                )
            }
        }
        .overlay {
            if searchModel.visibleCollections.isEmpty {
                ContentUnavailableView.search(text: searchModel.searchText)
            }
        }
        .navigationTitle(kind.title)
        .searchable(text: searchBinding)
        .onAppear {
            searchModel.updateCollections(mediaLibrary.collections(for: kind))
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchModel.searchText },
            set: { searchModel.searchText = $0 }
        )
    }
}

struct CollectionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 32, height: 32)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
