import Foundation
import MediaPlayer
import Observation
import UIKit

enum LibraryAccessState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum LibraryCollectionKind: String, CaseIterable, Identifiable, Sendable {
    case albums
    case artists
    case genres
    case composers
    case playlists

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .composers: "Composers"
        case .playlists: "Music Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .composers: "music.quarternote.3"
        case .playlists: "music.note.list"
        }
    }
}

struct LibraryTrack: Identifiable, Hashable, Sendable {
    let id: String
    let persistentID: String
    let playbackStoreID: String
    let title: String
    let artist: String
    let albumTitle: String
    let composer: String
    let genre: String
    let playbackDuration: TimeInterval
    let isCloudItem: Bool

    init(item: MPMediaItem) {
        let persistentID = String(item.persistentID)
        id = persistentID
        self.persistentID = persistentID
        playbackStoreID = item.playbackStoreID
        title = item.title ?? String(localized: "Unknown Title")
        artist = item.artist ?? String(localized: "Unknown Artist")
        albumTitle = item.albumTitle ?? String(localized: "Unknown Album")
        composer = item.composer ?? ""
        genre = item.genre ?? ""
        playbackDuration = item.playbackDuration
        isCloudItem = item.isCloudItem
    }

    init(
        persistentID: String,
        playbackStoreID: String = "",
        title: String,
        artist: String,
        albumTitle: String,
        composer: String = "",
        genre: String = "",
        playbackDuration: TimeInterval = 0,
        isCloudItem: Bool = false
    ) {
        id = persistentID
        self.persistentID = persistentID
        self.playbackStoreID = playbackStoreID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.composer = composer
        self.genre = genre
        self.playbackDuration = playbackDuration
        self.isCloudItem = isCloudItem
    }

    init(entry: PlaylistEntry) {
        self.init(
            persistentID: entry.mediaPersistentID,
            playbackStoreID: entry.playbackStoreID,
            title: entry.title,
            artist: entry.artist,
            albumTitle: entry.albumTitle,
            playbackDuration: entry.playbackDuration
        )
    }
}

struct LibraryCollection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let trackIDs: [LibraryTrack.ID]
}

protocol MediaLibraryProviding: AnyObject {
    var accessState: LibraryAccessState { get }
    var tracks: [LibraryTrack] { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get }

    func requestAccess() async
    func loadLibrary()
    func collections(for kind: LibraryCollectionKind) -> [LibraryCollection]
    func tracks(withIDs ids: [LibraryTrack.ID]) -> [LibraryTrack]
}

@MainActor
@Observable
final class MediaLibraryService: MediaLibraryProviding {
    private(set) var accessState: LibraryAccessState
    private(set) var tracks: [LibraryTrack] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var libraryRevision = 0

    private var collectionsByKind: [LibraryCollectionKind: [LibraryCollection]] = [:]
    private var mediaItemsByPersistentID: [String: MPMediaItem] = [:]
    private var mediaItemsByStoreID: [String: MPMediaItem] = [:]
    private let mediaLibrary = MPMediaLibrary.default()
    private var libraryChangeTask: Task<Void, Never>?

    init() {
        accessState = Self.mapAuthorizationStatus(
            MPMediaLibrary.authorizationStatus()
        )

        if accessState == .authorized {
            startObservingLibraryChanges()
            loadLibrary()
        }
    }

    func requestAccess() async {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        accessState = Self.mapAuthorizationStatus(status)

        if accessState == .authorized {
            startObservingLibraryChanges()
            loadLibrary()
        }
    }

    func loadLibrary() {
        guard accessState == .authorized else { return }

        isLoading = true
        errorMessage = nil

        let items = MPMediaQuery.songs().items ?? []
        var trackValues: [LibraryTrack] = []
        var itemsByPersistentID: [String: MPMediaItem] = [:]
        var itemsByStoreID: [String: MPMediaItem] = [:]

        for item in items where item.mediaType.contains(.music) {
            let track = LibraryTrack(item: item)
            trackValues.append(track)
            itemsByPersistentID[track.persistentID] = item

            if !track.playbackStoreID.isEmpty && track.playbackStoreID != "0" {
                itemsByStoreID[track.playbackStoreID] = item
            }
        }

        tracks = trackValues.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        mediaItemsByPersistentID = itemsByPersistentID
        mediaItemsByStoreID = itemsByStoreID

        collectionsByKind = [
            .albums: makeCollections(query: .albums(), kind: .albums),
            .artists: makeCollections(query: .artists(), kind: .artists),
            .genres: makeCollections(query: .genres(), kind: .genres),
            .composers: makeCollections(query: .composers(), kind: .composers),
            .playlists: makeCollections(query: .playlists(), kind: .playlists)
        ]

        libraryRevision += 1
        isLoading = false
    }

    func collections(for kind: LibraryCollectionKind) -> [LibraryCollection] {
        collectionsByKind[kind] ?? []
    }

    func searchableCollections() -> [(LibraryCollectionKind, LibraryCollection)] {
        LibraryCollectionKind.allCases.flatMap { kind in
            collections(for: kind).map { (kind, $0) }
        }
    }

    func tracks(withIDs ids: [LibraryTrack.ID]) -> [LibraryTrack] {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return ids.compactMap { tracksByID[$0] }
    }

    func resolvedTrack(for entry: PlaylistEntry) -> LibraryTrack? {
        if let item = mediaItemsByPersistentID[entry.mediaPersistentID] {
            return LibraryTrack(item: item)
        }

        if !entry.playbackStoreID.isEmpty,
           let item = mediaItemsByStoreID[entry.playbackStoreID] {
            return LibraryTrack(item: item)
        }

        return nil
    }

    func mediaItems(for tracks: [LibraryTrack]) -> [MPMediaItem] {
        tracks.compactMap { track in
            mediaItemsByPersistentID[track.persistentID]
                ?? mediaItemsByStoreID[track.playbackStoreID]
        }
    }

    func artwork(for trackID: LibraryTrack.ID, size: CGSize) -> UIImage? {
        mediaItemsByPersistentID[trackID]?.artwork?.image(at: size)
    }

    private func makeCollections(
        query: MPMediaQuery,
        kind: LibraryCollectionKind
    ) -> [LibraryCollection] {
        let collections = query.collections ?? []

        return collections.compactMap { collection in
            let itemTracks = collection.items.map(LibraryTrack.init)
            guard !itemTracks.isEmpty else { return nil }

            let representativeItem = collection.representativeItem
            let title: String

            switch kind {
            case .albums:
                title = representativeItem?.albumTitle ?? String(localized: "Unknown Album")
            case .artists:
                title = representativeItem?.artist ?? String(localized: "Unknown Artist")
            case .genres:
                title = representativeItem?.genre ?? String(localized: "Unknown Genre")
            case .composers:
                title = representativeItem?.composer ?? String(localized: "Unknown Composer")
            case .playlists:
                title = (collection as? MPMediaPlaylist)?.name
                    ?? String(localized: "Untitled Playlist")
            }

            return LibraryCollection(
                id: "\(kind.rawValue)-\(collection.persistentID)",
                title: title,
                subtitle: String(
                    localized: "\(itemTracks.count) songs",
                    comment: "Number of songs in a music collection."
                ),
                trackIDs: itemTracks.map(\.id)
            )
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func startObservingLibraryChanges() {
        guard libraryChangeTask == nil else { return }

        mediaLibrary.beginGeneratingLibraryChangeNotifications()
        libraryChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .MPMediaLibraryDidChange
            ) {
                guard !Task.isCancelled else { return }
                self?.loadLibrary()
            }
        }
    }

    private static func mapAuthorizationStatus(
        _ status: MPMediaLibraryAuthorizationStatus
    ) -> LibraryAccessState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }
}
