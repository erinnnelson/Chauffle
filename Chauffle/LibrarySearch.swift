import Foundation
import Observation

enum LibrarySearchCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case song
    case artist
    case album
    case composer
    case genre
    case musicPlaylist
    case chauffeurPlaylist
    case set

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .song: "Songs"
        case .artist: "Artists"
        case .album: "Albums"
        case .composer: "Composers"
        case .genre: "Genres"
        case .musicPlaylist: "Music Playlists"
        case .chauffeurPlaylist: "Chauffle Playlists"
        case .set: "Sets"
        }
    }

    var systemImage: String {
        switch self {
        case .song: "music.note"
        case .artist: "music.mic"
        case .album: "square.stack"
        case .composer: "music.quarternote.3"
        case .genre: "guitars"
        case .musicPlaylist, .chauffeurPlaylist: "music.note.list"
        case .set: "rectangle.stack"
        }
    }
}

enum LibrarySearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case songs
    case artists
    case albums
    case playlists
    case more

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        case .playlists: "Playlists"
        case .more: "More"
        }
    }

    nonisolated func includes(_ category: LibrarySearchCategory) -> Bool {
        switch self {
        case .all:
            true
        case .songs:
            category == .song
        case .artists:
            category == .artist
        case .albums:
            category == .album
        case .playlists:
            category == .musicPlaylist
                || category == .chauffeurPlaylist
                || category == .set
        case .more:
            category == .composer || category == .genre
        }
    }
}

enum LibrarySearchSource: Hashable, Sendable {
    case track(String)
    case collection(LibraryCollectionKind, String)
    case chauffeurPlaylist(UUID)
    case set(playlistID: UUID, setID: UUID)
}

struct LibrarySearchField: Hashable, Sendable {
    let normalizedValue: String
    let tokens: [String]
    let weight: Int

    nonisolated init(_ value: String, weight: Int) {
        normalizedValue = SearchTextNormalizer.normalize(value)
        tokens = normalizedValue.split(separator: " ").map(String.init)
        self.weight = weight
    }
}

struct LibrarySearchDocument: Identifiable, Hashable, Sendable {
    let id: String
    let source: LibrarySearchSource
    let category: LibrarySearchCategory
    let title: String
    let subtitle: String
    let trackIDs: [LibraryTrack.ID]
    let fields: [LibrarySearchField]
}

struct RankedLibrarySearchResult: Identifiable, Hashable, Sendable {
    var id: String { document.id }

    let document: LibrarySearchDocument
    let score: Int
}

struct LibrarySearchResults: Equatable, Sendable {
    nonisolated static let empty = LibrarySearchResults()

    var topResults: [RankedLibrarySearchResult] = []
    var resultsByCategory: [LibrarySearchCategory: [RankedLibrarySearchResult]] = [:]
    var suggestion: String?

    nonisolated init(
        topResults: [RankedLibrarySearchResult] = [],
        resultsByCategory: [LibrarySearchCategory: [RankedLibrarySearchResult]] = [:],
        suggestion: String? = nil
    ) {
        self.topResults = topResults
        self.resultsByCategory = resultsByCategory
        self.suggestion = suggestion
    }

    nonisolated var isEmpty: Bool {
        resultsByCategory.values.allSatisfy(\.isEmpty)
    }

    nonisolated func results(
        for category: LibrarySearchCategory
    ) -> [RankedLibrarySearchResult] {
        resultsByCategory[category] ?? []
    }
}

enum SearchTextNormalizer {
    nonisolated static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum LibrarySearchEngine {
    nonisolated static func search(
        query: String,
        documents: [LibrarySearchDocument],
        scope: LibrarySearchScope
    ) -> LibrarySearchResults {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty else { return .empty }

        let ranked = documents.compactMap { document -> RankedLibrarySearchResult? in
            guard scope.includes(document.category),
                  let score = score(
                    document: document,
                    normalizedQuery: normalizedQuery,
                    queryTokens: queryTokens
                  ) else {
                return nil
            }
            return RankedLibrarySearchResult(document: document, score: score)
        }
        .sorted(by: rankedBefore)

        var grouped: [LibrarySearchCategory: [RankedLibrarySearchResult]] = [:]
        for result in ranked {
            grouped[result.document.category, default: []].append(result)
        }

        return LibrarySearchResults(
            topResults: scope == .all ? Array(ranked.prefix(3)) : [],
            resultsByCategory: grouped,
            suggestion: ranked.isEmpty
                ? closestSuggestion(for: queryTokens, in: documents, scope: scope)
                : nil
        )
    }

    nonisolated static func rankedTracks(
        query: String,
        tracks: [LibraryTrack]
    ) -> [LibraryTrack] {
        let documents = tracks.map(LibrarySearchDocument.trackDocument)
        let results = search(query: query, documents: documents, scope: .songs)
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return results.results(for: .song).compactMap { result in
            guard case .track(let id) = result.document.source else { return nil }
            return tracksByID[id]
        }
    }

    nonisolated private static func score(
        document: LibrarySearchDocument,
        normalizedQuery: String,
        queryTokens: [String]
    ) -> Int? {
        var total = 0

        for queryToken in queryTokens {
            var bestTokenScore: Int?
            for field in document.fields where !field.normalizedValue.isEmpty {
                if field.normalizedValue == normalizedQuery {
                    bestTokenScore = max(bestTokenScore ?? 0, 180 * field.weight)
                } else if field.normalizedValue.hasPrefix(normalizedQuery) {
                    bestTokenScore = max(bestTokenScore ?? 0, 130 * field.weight)
                } else if field.normalizedValue.contains(normalizedQuery) {
                    bestTokenScore = max(bestTokenScore ?? 0, 90 * field.weight)
                }

                for candidate in field.tokens {
                    let candidateScore: Int?
                    if candidate == queryToken {
                        candidateScore = 115 * field.weight
                    } else if candidate.hasPrefix(queryToken) {
                        candidateScore = 85 * field.weight
                    } else if candidate.contains(queryToken) {
                        candidateScore = 60 * field.weight
                    } else if let distance = acceptedEditDistance(
                        queryToken: queryToken,
                        candidate: candidate
                    ) {
                        candidateScore = (48 - distance * 12) * field.weight
                    } else {
                        candidateScore = nil
                    }

                    if let candidateScore {
                        bestTokenScore = max(bestTokenScore ?? 0, candidateScore)
                    }
                }
            }

            guard let bestTokenScore else { return nil }
            total += bestTokenScore
        }

        return total
    }

    nonisolated private static func acceptedEditDistance(
        queryToken: String,
        candidate: String
    ) -> Int? {
        let queryLength = queryToken.count
        let maximumDistance: Int
        switch queryLength {
        case 0...2: return nil
        case 3...5: maximumDistance = 1
        default: maximumDistance = min(2, max(1, queryLength / 4))
        }

        guard abs(queryLength - candidate.count) <= maximumDistance else { return nil }
        let distance = damerauLevenshteinDistance(queryToken, candidate)
        return distance <= maximumDistance ? distance : nil
    }

    nonisolated private static func damerauLevenshteinDistance(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var matrix = Array(
            repeating: Array(repeating: 0, count: right.count + 1),
            count: left.count + 1
        )
        for index in 0...left.count { matrix[index][0] = index }
        for index in 0...right.count { matrix[0][index] = index }

        for leftIndex in 1...left.count {
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                matrix[leftIndex][rightIndex] = min(
                    matrix[leftIndex - 1][rightIndex] + 1,
                    matrix[leftIndex][rightIndex - 1] + 1,
                    matrix[leftIndex - 1][rightIndex - 1] + substitutionCost
                )

                if leftIndex > 1,
                   rightIndex > 1,
                   left[leftIndex - 1] == right[rightIndex - 2],
                   left[leftIndex - 2] == right[rightIndex - 1] {
                    matrix[leftIndex][rightIndex] = min(
                        matrix[leftIndex][rightIndex],
                        matrix[leftIndex - 2][rightIndex - 2] + 1
                    )
                }
            }
        }
        return matrix[left.count][right.count]
    }

    nonisolated private static func rankedBefore(
        _ lhs: RankedLibrarySearchResult,
        _ rhs: RankedLibrarySearchResult
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.document.title.localizedStandardCompare(rhs.document.title)
            == .orderedAscending
    }

    nonisolated private static func closestSuggestion(
        for queryTokens: [String],
        in documents: [LibrarySearchDocument],
        scope: LibrarySearchScope
    ) -> String? {
        guard queryTokens.count == 1, let query = queryTokens.first, query.count >= 3 else {
            return nil
        }

        var best: (distance: Int, title: String)?
        for document in documents where scope.includes(document.category) {
            guard let titleField = document.fields.first else { continue }
            for token in titleField.tokens {
                let distance = damerauLevenshteinDistance(query, token)
                guard distance <= min(3, max(1, query.count / 3)) else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, document.title)
                }
            }
        }
        return best?.title
    }
}

@MainActor
@Observable
final class LibrarySearchModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    var scope: LibrarySearchScope = .all {
        didSet {
            guard scope != oldValue else { return }
            scheduleSearch(immediately: true)
        }
    }

    private(set) var results = LibrarySearchResults.empty
    private(set) var recentQueries: [String]
    private(set) var isSearching = false

    @ObservationIgnored private var documents: [LibrarySearchDocument] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let storesHistory: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyKey = "Chauffle.RecentLibrarySearches"

    init(storesHistory: Bool = true, defaults: UserDefaults = .standard) {
        self.storesHistory = storesHistory
        self.defaults = defaults
        recentQueries = storesHistory ? defaults.stringArray(forKey: historyKey) ?? [] : []
    }

    func rebuildIndex(
        tracks: [LibraryTrack],
        collections: [(LibraryCollectionKind, LibraryCollection)],
        playlists: [AppPlaylist],
        includeChauffle: Bool
    ) {
        var newDocuments = tracks.map(LibrarySearchDocument.trackDocument)
        newDocuments.append(contentsOf: collections.map { kind, collection in
            LibrarySearchDocument.collectionDocument(kind: kind, collection: collection)
        })

        if includeChauffle {
            for playlist in playlists {
                newDocuments.append(.chaufflePlaylistDocument(playlist))
                newDocuments.append(contentsOf: playlist.sets.map {
                    .setDocument($0, playlist: playlist)
                })
            }
        }

        documents = newDocuments
        scheduleSearch(immediately: true)
    }

    func recordCurrentQuery() {
        recordQuery(query)
    }

    func useRecentQuery(_ value: String) {
        query = value
        recordQuery(value)
    }

    func removeRecentQuery(_ value: String) {
        recentQueries.removeAll { $0 == value }
        persistHistory()
    }

    func clearRecentQueries() {
        recentQueries = []
        persistHistory()
    }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let currentQuery = query
        let currentScope = scope
        let currentDocuments = documents

        guard !SearchTextNormalizer.normalize(currentQuery).isEmpty else {
            results = .empty
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }

            let newResults = await Task.detached(priority: .userInitiated) {
                LibrarySearchEngine.search(
                    query: currentQuery,
                    documents: currentDocuments,
                    scope: currentScope
                )
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.query == currentQuery,
                  self.scope == currentScope else {
                return
            }
            self.results = newResults
            self.isSearching = false
        }
    }

    private func recordQuery(_ value: String) {
        guard storesHistory else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = SearchTextNormalizer.normalize(trimmed)
        recentQueries.removeAll { SearchTextNormalizer.normalize($0) == normalized }
        recentQueries.insert(trimmed, at: 0)
        recentQueries = Array(recentQueries.prefix(8))
        persistHistory()
    }

    private func persistHistory() {
        guard storesHistory else { return }
        defaults.set(recentQueries, forKey: historyKey)
    }
}

private extension LibrarySearchDocument {
    nonisolated static func trackDocument(_ track: LibraryTrack) -> LibrarySearchDocument {
        LibrarySearchDocument(
            id: "song-\(track.id)",
            source: .track(track.id),
            category: .song,
            title: track.title,
            subtitle: [track.artist, track.albumTitle]
                .filter { !$0.isEmpty }
                .joined(separator: " • "),
            trackIDs: [track.id],
            fields: [
                LibrarySearchField(track.title, weight: 12),
                LibrarySearchField(track.artist, weight: 8),
                LibrarySearchField(track.albumTitle, weight: 6),
                LibrarySearchField(track.composer, weight: 5),
                LibrarySearchField(track.genre, weight: 4)
            ]
        )
    }

    nonisolated static func collectionDocument(
        kind: LibraryCollectionKind,
        collection: LibraryCollection
    ) -> LibrarySearchDocument {
        let category: LibrarySearchCategory = switch kind {
        case .albums: .album
        case .artists: .artist
        case .genres: .genre
        case .composers: .composer
        case .playlists: .musicPlaylist
        }
        return LibrarySearchDocument(
            id: collection.id,
            source: .collection(kind, collection.id),
            category: category,
            title: collection.title,
            subtitle: collection.subtitle,
            trackIDs: collection.trackIDs,
            fields: [LibrarySearchField(collection.title, weight: 14)]
        )
    }

    static func chaufflePlaylistFields(_ playlist: AppPlaylist) -> [LibrarySearchField] {
        [LibrarySearchField(playlist.name, weight: 14)]
    }

    static func chaufflePlaylistDocument(_ playlist: AppPlaylist) -> LibrarySearchDocument {
        LibrarySearchDocument(
            id: "chauffle-playlist-\(playlist.id.uuidString)",
            source: .chauffeurPlaylist(playlist.id),
            category: .chauffeurPlaylist,
            title: playlist.name,
            subtitle: localizedSongCount(playlist.orderedEntries.count),
            trackIDs: [],
            fields: chaufflePlaylistFields(playlist)
        )
    }

    static func setDocument(
        _ set: PlaylistGroup,
        playlist: AppPlaylist
    ) -> LibrarySearchDocument {
        LibrarySearchDocument(
            id: "chauffle-set-\(set.id.uuidString)",
            source: .set(playlistID: playlist.id, setID: set.id),
            category: .set,
            title: set.name,
            subtitle: String(localized: "In \(playlist.name) • \(localizedSongCount(set.entries.count))"),
            trackIDs: [],
            fields: [
                LibrarySearchField(set.name, weight: 14),
                LibrarySearchField(playlist.name, weight: 6)
            ]
        )
    }
}
