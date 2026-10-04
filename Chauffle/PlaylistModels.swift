import Foundation
import SwiftData
import SwiftUI

enum PlaylistSelectionMode: String, CaseIterable, Identifiable {
    case all
    case one
    case count

    var id: Self { self }
}

enum PlaylistOrderMode: String, CaseIterable, Identifiable {
    case inOrder
    case random

    var id: Self { self }
}

enum PlaylistContentItem: Identifiable {
    case song(PlaylistEntry)
    case set(PlaylistGroup)

    var id: UUID {
        switch self {
        case .song(let entry): entry.id
        case .set(let group): group.id
        }
    }

    var position: Int {
        switch self {
        case .song(let entry): entry.position
        case .set(let group): group.position
        }
    }
}

struct RemovedPlaylistEntrySnapshot: Equatable {
    let id: UUID
    let groupID: UUID
    let groupIsDefault: Bool
    let position: Int
    let mediaPersistentID: String
    let playbackStoreID: String
    let title: String
    let artist: String
    let albumTitle: String
    let playbackDuration: TimeInterval
}

@Model
final class AppPlaylist {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var orderModeRawValue: String = PlaylistOrderMode.inOrder.rawValue
    var isLooping: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \PlaylistGroup.playlist)
    var groups: [PlaylistGroup]

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = Date()
        updatedAt = Date()

        let defaultGroup = PlaylistGroup(
            name: String(localized: "Playlist"),
            position: 0,
            isDefault: true
        )
        groups = [defaultGroup]
    }

    var orderedGroups: [PlaylistGroup] {
        groups.sorted { $0.position < $1.position }
    }

    var orderedEntries: [PlaylistEntry] {
        orderedContent.flatMap { item in
            switch item {
            case .song(let entry): [entry]
            case .set(let group): group.orderedEntries
            }
        }
    }

    var orderMode: PlaylistOrderMode {
        get { PlaylistOrderMode(rawValue: orderModeRawValue) ?? .inOrder }
        set {
            orderModeRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var sets: [PlaylistGroup] {
        groups.filter { !$0.isDefault }.sorted { $0.position < $1.position }
    }

    var orderedContent: [PlaylistContentItem] {
        let songs = defaultGroup().orderedEntries.map(PlaylistContentItem.song)
        let setItems = sets.map(PlaylistContentItem.set)
        return (songs + setItems).sorted { lhs, rhs in
            if lhs.position == rhs.position {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.position < rhs.position
        }
    }

    func makeAddProposal(for tracks: [LibraryTrack]) -> PlaylistAddProposal {
        let existingIDs = Set(orderedEntries.map(\.mediaPersistentID))
        let duplicateIDs = Set(
            tracks
                .filter { existingIDs.contains($0.persistentID) }
                .map(\.id)
        )

        return PlaylistAddProposal(
            requestedTracks: tracks,
            duplicateTrackIDs: duplicateIDs
        )
    }

    func add(_ tracks: [LibraryTrack], to destination: PlaylistGroup? = nil) {
        guard !tracks.isEmpty else { return }

        let group = destination ?? defaultGroup()
        var nextPosition: Int

        if group.isDefault {
            nextPosition = (orderedContent.map(\.position).max() ?? -1) + 1
        } else {
            nextPosition = (group.entries.map(\.position).max() ?? -1) + 1
        }

        for track in tracks {
            let entry = PlaylistEntry(track: track, position: nextPosition)
            group.entries.append(entry)
            nextPosition += 1
        }

        updatedAt = Date()
    }

    @discardableResult
    func createSet(named name: String) -> PlaylistGroup {
        let set = PlaylistGroup(
            name: name,
            position: (orderedContent.map(\.position).max() ?? -1) + 1
        )
        groups.append(set)
        updatedAt = Date()
        return set
    }

    func move(_ entry: PlaylistEntry, to destination: PlaylistGroup) {
        guard entry.group?.id != destination.id else { return }
        let source = entry.group
        source?.entries.removeAll { $0.id == entry.id }

        if destination.isDefault {
            entry.position = (orderedContent.map(\.position).max() ?? -1) + 1
        } else {
            entry.position = (destination.entries.map(\.position).max() ?? -1) + 1
        }
        destination.entries.append(entry)

        if let source, !source.isDefault {
            normalizeEntryPositions(in: source)
        }
        normalizeTopLevelPositions()
    }

    func remove(_ entry: PlaylistEntry) -> RemovedPlaylistEntrySnapshot? {
        guard let group = entry.group,
              groups.contains(where: { $0.id == group.id }) else {
            return nil
        }

        let snapshot = RemovedPlaylistEntrySnapshot(
            id: entry.id,
            groupID: group.id,
            groupIsDefault: group.isDefault,
            position: entry.position,
            mediaPersistentID: entry.mediaPersistentID,
            playbackStoreID: entry.playbackStoreID,
            title: entry.title,
            artist: entry.artist,
            albumTitle: entry.albumTitle,
            playbackDuration: entry.playbackDuration
        )

        group.entries.removeAll { $0.id == entry.id }
        if group.isDefault {
            normalizeTopLevelPositions()
        } else {
            normalizeEntryPositions(in: group)
        }
        updatedAt = Date()
        return snapshot
    }

    @discardableResult
    func restore(_ snapshot: RemovedPlaylistEntrySnapshot) -> PlaylistEntry? {
        guard let group = groups.first(where: { $0.id == snapshot.groupID }),
              group.isDefault == snapshot.groupIsDefault else {
            return nil
        }

        if group.isDefault {
            for item in orderedContent where item.position >= snapshot.position {
                switch item {
                case .song(let entry): entry.position += 1
                case .set(let set): set.position += 1
                }
            }
        } else {
            for entry in group.entries where entry.position >= snapshot.position {
                entry.position += 1
            }
        }

        let entry = PlaylistEntry(snapshot: snapshot)
        group.entries.append(entry)
        updatedAt = Date()
        return entry
    }

    func deleteSet(_ set: PlaylistGroup, keepingSongs: Bool) {
        guard !set.isDefault else { return }
        let content = orderedContent
        let defaultDestination = defaultGroup()
        var replacement: [PlaylistContentItem] = []

        for item in content {
            if case .set(let candidate) = item, candidate.id == set.id {
                if keepingSongs {
                    for entry in set.orderedEntries {
                        set.entries.removeAll { $0.id == entry.id }
                        defaultDestination.entries.append(entry)
                        replacement.append(.song(entry))
                    }
                }
            } else {
                replacement.append(item)
            }
        }

        groups.removeAll { $0.id == set.id }
        for (index, item) in replacement.enumerated() {
            switch item {
            case .song(let entry): entry.position = index
            case .set(let group): group.position = index
            }
        }
        updatedAt = Date()
    }

    func moveTopLevel(from source: IndexSet, to destination: Int) {
        var content = orderedContent
        content.move(fromOffsets: source, toOffset: destination)

        for (index, item) in content.enumerated() {
            switch item {
            case .song(let entry): entry.position = index
            case .set(let group): group.position = index
            }
        }
        updatedAt = Date()
    }

    func defaultGroup() -> PlaylistGroup {
        if let group = orderedGroups.first(where: \.isDefault) {
            return group
        }

        let group = PlaylistGroup(
            name: String(localized: "Playlist"),
            position: 0,
            isDefault: true
        )
        groups.append(group)
        return group
    }

    func normalizeEntryPositions() {
        for group in sets {
            normalizeEntryPositions(in: group)
        }
        normalizeTopLevelPositions()
        updatedAt = Date()
    }

    func normalizeEntryPositions(in group: PlaylistGroup) {
        for (index, entry) in group.orderedEntries.enumerated() {
            entry.position = index
        }
        updatedAt = Date()
    }

    func normalizeTopLevelPositions() {
        for (index, item) in orderedContent.enumerated() {
            switch item {
            case .song(let entry): entry.position = index
            case .set(let group): group.position = index
            }
        }
        updatedAt = Date()
    }
}

@Model
final class PlaylistGroup {
    var id: UUID
    var name: String
    var position: Int
    var isDefault: Bool
    var selectionModeRawValue: String
    var selectionCount: Int?
    var orderModeRawValue: String
    var playlist: AppPlaylist?

    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.group)
    var entries: [PlaylistEntry]

    init(
        name: String,
        position: Int,
        isDefault: Bool = false,
        selectionMode: PlaylistSelectionMode = .all,
        selectionCount: Int? = nil,
        orderMode: PlaylistOrderMode = .inOrder
    ) {
        id = UUID()
        self.name = name
        self.position = position
        self.isDefault = isDefault
        selectionModeRawValue = selectionMode.rawValue
        self.selectionCount = selectionCount
        orderModeRawValue = orderMode.rawValue
        entries = []
    }

    var selectionMode: PlaylistSelectionMode {
        get { PlaylistSelectionMode(rawValue: selectionModeRawValue) ?? .all }
        set { selectionModeRawValue = newValue.rawValue }
    }

    var orderMode: PlaylistOrderMode {
        get { PlaylistOrderMode(rawValue: orderModeRawValue) ?? .inOrder }
        set { orderModeRawValue = newValue.rawValue }
    }

    var orderedEntries: [PlaylistEntry] {
        entries.sorted { $0.position < $1.position }
    }
}

@Model
final class PlaylistEntry {
    var id: UUID
    var position: Int
    var mediaPersistentID: String
    var playbackStoreID: String
    var title: String
    var artist: String
    var albumTitle: String
    var playbackDuration: TimeInterval
    var group: PlaylistGroup?

    init(track: LibraryTrack, position: Int) {
        id = UUID()
        self.position = position
        mediaPersistentID = track.persistentID
        playbackStoreID = track.playbackStoreID
        title = track.title
        artist = track.artist
        albumTitle = track.albumTitle
        playbackDuration = track.playbackDuration
    }

    init(snapshot: RemovedPlaylistEntrySnapshot) {
        id = snapshot.id
        position = snapshot.position
        mediaPersistentID = snapshot.mediaPersistentID
        playbackStoreID = snapshot.playbackStoreID
        title = snapshot.title
        artist = snapshot.artist
        albumTitle = snapshot.albumTitle
        playbackDuration = snapshot.playbackDuration
    }
}

struct PlaylistAddProposal {
    let requestedTracks: [LibraryTrack]
    let duplicateTrackIDs: Set<LibraryTrack.ID>

    var duplicateTracks: [LibraryTrack] {
        requestedTracks.filter { duplicateTrackIDs.contains($0.id) }
    }

    var newTracks: [LibraryTrack] {
        requestedTracks.filter { !duplicateTrackIDs.contains($0.id) }
    }

    var hasDuplicates: Bool {
        !duplicateTrackIDs.isEmpty
    }
}
