import Foundation

struct PlannedPlaylistEntry: Identifiable {
    let entry: PlaylistEntry
    let set: PlaylistGroup?

    var id: UUID { entry.id }
}

protocol PlaylistQueuePlanning {
    func entries(for playlist: AppPlaylist) -> [PlaylistEntry]
    func plannedEntries(
        for playlist: AppPlaylist,
        startingAt entryID: UUID?
    ) -> [PlannedPlaylistEntry]
}

struct PlaylistQueuePlanner: PlaylistQueuePlanning {
    typealias RandomIndex = (Int) -> Int

    private let randomIndex: RandomIndex

    init(randomIndex: @escaping RandomIndex = { upperBound in
        Int.random(in: 0..<upperBound)
    }) {
        self.randomIndex = randomIndex
    }

    func entries(for playlist: AppPlaylist) -> [PlaylistEntry] {
        plannedEntries(for: playlist, startingAt: nil).map(\.entry)
    }

    func plannedEntries(
        for playlist: AppPlaylist,
        startingAt entryID: UUID? = nil
    ) -> [PlannedPlaylistEntry] {
        var content = playlist.orderedContent

        if playlist.orderMode == .random {
            content = shuffled(content)
        }

        if let entryID,
           let contentIndex = content.firstIndex(where: { contains($0, entryID: entryID) }) {
            if playlist.orderMode == .random {
                let startingItem = content.remove(at: contentIndex)
                content.insert(startingItem, at: 0)
            } else {
                content = Array(content[contentIndex...])
            }
        }

        return content.flatMap { item in
            switch item {
            case .song(let entry):
                return [PlannedPlaylistEntry(entry: entry, set: nil)]
            case .set(let set):
                return entries(for: set, forcedEntryID: entryID)
            }
        }
    }

    private func entries(
        for set: PlaylistGroup,
        forcedEntryID: UUID?
    ) -> [PlannedPlaylistEntry] {
        let ordered = set.orderedEntries
        guard !ordered.isEmpty else { return [] }

        let desiredCount: Int
        switch set.selectionMode {
        case .all:
            desiredCount = ordered.count
        case .one:
            desiredCount = 1
        case .count:
            desiredCount = min(max(set.selectionCount ?? 1, 1), ordered.count)
        }

        var selected: [PlaylistEntry]
        if let forcedEntryID,
           let forcedIndex = ordered.firstIndex(where: { $0.id == forcedEntryID }) {
            let forced = ordered[forcedIndex]
            var remaining = Array(ordered[(forcedIndex + 1)...])
                + Array(ordered[..<forcedIndex])
            if set.orderMode == .random {
                remaining = shuffled(remaining)
            }
            selected = [forced] + remaining.prefix(max(desiredCount - 1, 0))
        } else {
            var candidates = ordered
            if set.orderMode == .random {
                candidates = shuffled(candidates)
            }
            selected = Array(candidates.prefix(desiredCount))
        }

        return selected.map { PlannedPlaylistEntry(entry: $0, set: set) }
    }

    private func contains(_ item: PlaylistContentItem, entryID: UUID) -> Bool {
        switch item {
        case .song(let entry): entry.id == entryID
        case .set(let set): set.entries.contains { $0.id == entryID }
        }
    }

    private func shuffled<Element>(_ values: [Element]) -> [Element] {
        guard values.count > 1 else { return values }
        var result = values

        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let candidate = min(max(randomIndex(index + 1), 0), index)
            if candidate != index {
                result.swapAt(index, candidate)
            }
        }
        return result
    }
}
