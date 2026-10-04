import Foundation
import Testing
@testable import Chauffle

@MainActor
struct MyAppTests {
    @Test
    func newPlaylistHasGroupReadyDefaults() {
        let playlist = AppPlaylist(name: "Road Trip")

        #expect(playlist.groups.count == 1)
        #expect(playlist.orderedGroups[0].isDefault)
        #expect(playlist.orderedGroups[0].selectionMode == .all)
        #expect(playlist.orderedGroups[0].orderMode == .inOrder)
    }

    @Test
    func duplicateProposalDoesNotMutatePlaylist() {
        let track = makeTrack(id: "101", title: "First Song")
        let playlist = AppPlaylist(name: "Favorites")
        playlist.add([track])

        let proposal = playlist.makeAddProposal(for: [track])

        #expect(proposal.hasDuplicates)
        #expect(proposal.duplicateTracks.map(\.id) == [track.id])
        #expect(proposal.newTracks.isEmpty)
        #expect(playlist.orderedEntries.count == 1)
    }

    @Test
    func acceptedDuplicatesHaveIndependentIdentityAndOrder() {
        let track = makeTrack(id: "101", title: "First Song")
        let playlist = AppPlaylist(name: "Favorites")

        playlist.add([track])
        playlist.add([track])

        let entries = playlist.orderedEntries
        #expect(entries.count == 2)
        #expect(entries[0].mediaPersistentID == entries[1].mediaPersistentID)
        #expect(entries[0].id != entries[1].id)
        #expect(entries.map(\.position) == [0, 1])
    }

    @Test
    func bulkProposalSeparatesNewSongsFromDuplicates() {
        let existing = makeTrack(id: "101", title: "Existing")
        let newTrack = makeTrack(id: "202", title: "New")
        let playlist = AppPlaylist(name: "Mix")
        playlist.add([existing])

        let proposal = playlist.makeAddProposal(for: [existing, newTrack])

        #expect(proposal.duplicateTracks.map(\.id) == [existing.id])
        #expect(proposal.newTracks.map(\.id) == [newTrack.id])
    }

    @Test
    func queuePlannerUsesGroupAndEntryPositions() {
        let playlist = AppPlaylist(name: "Ordered")
        let first = makeTrack(id: "101", title: "First")
        let second = makeTrack(id: "202", title: "Second")
        playlist.add([second, first])

        let group = playlist.defaultGroup()
        group.entries[0].position = 1
        group.entries[1].position = 0

        let planned = PlaylistQueuePlanner().entries(for: playlist)

        #expect(planned.map(\.title) == ["First", "Second"])
    }

    @Test
    func unknownGroupPoliciesUseSafeDefaults() {
        let playlist = AppPlaylist(name: "Future Safe")
        let group = playlist.defaultGroup()
        group.selectionModeRawValue = "future-selection"
        group.orderModeRawValue = "future-order"

        #expect(group.selectionMode == .all)
        #expect(group.orderMode == .inOrder)
    }

    @Test
    func setsInterleaveWithLooseSongs() {
        let playlist = AppPlaylist(name: "Show")
        playlist.add([
            makeTrack(id: "1", title: "First"),
            makeTrack(id: "2", title: "Second")
        ])
        let set = playlist.createSet(named: "Dance Set")
        playlist.add([makeTrack(id: "3", title: "Inside Set")], to: set)
        playlist.add([makeTrack(id: "4", title: "Third")])

        #expect(playlist.orderedEntries.map(\.title) == [
            "First", "Second", "Inside Set", "Third"
        ])
    }

    @Test
    func setCountInOrderSelectsFirstSongs() {
        let playlist = AppPlaylist(name: "Counted")
        let set = playlist.createSet(named: "Three")
        playlist.add([
            makeTrack(id: "1", title: "One"),
            makeTrack(id: "2", title: "Two"),
            makeTrack(id: "3", title: "Three")
        ], to: set)
        set.selectionMode = .count
        set.selectionCount = 2

        let planned = PlaylistQueuePlanner().entries(for: playlist)

        #expect(planned.map(\.title) == ["One", "Two"])
    }

    @Test
    func randomSetCountDoesNotRepeatEntriesWithinCycle() {
        let playlist = AppPlaylist(name: "Random")
        let set = playlist.createSet(named: "Choices")
        playlist.add([
            makeTrack(id: "1", title: "One"),
            makeTrack(id: "2", title: "Two"),
            makeTrack(id: "3", title: "Three")
        ], to: set)
        set.selectionMode = .count
        set.selectionCount = 2
        set.orderMode = .random

        let planned = PlaylistQueuePlanner(randomIndex: { _ in 0 }).entries(for: playlist)

        #expect(planned.count == 2)
        #expect(Set(planned.map(\.id)).count == 2)
    }

    @Test
    func tappedSetSongCountsTowardSelection() {
        let playlist = AppPlaylist(name: "Tap")
        let set = playlist.createSet(named: "Pair")
        playlist.add([
            makeTrack(id: "1", title: "One"),
            makeTrack(id: "2", title: "Two"),
            makeTrack(id: "3", title: "Three")
        ], to: set)
        set.selectionMode = .count
        set.selectionCount = 2
        let tapped = set.orderedEntries[1]

        let planned = PlaylistQueuePlanner().plannedEntries(
            for: playlist,
            startingAt: tapped.id
        )

        #expect(planned.count == 2)
        #expect(planned.first?.entry.id == tapped.id)
    }

    @Test
    func deletingSetCanKeepSongsAtSetPosition() {
        let playlist = AppPlaylist(name: "Keep")
        playlist.add([makeTrack(id: "1", title: "Before")])
        let set = playlist.createSet(named: "Temporary")
        playlist.add([makeTrack(id: "2", title: "Kept")], to: set)
        playlist.add([makeTrack(id: "3", title: "After")])

        playlist.deleteSet(set, keepingSongs: true)

        #expect(playlist.sets.isEmpty)
        #expect(playlist.orderedEntries.map(\.title) == ["Before", "Kept", "After"])
    }

    @Test
    func removedParentSongRestoresToOriginalInterleavedPosition() throws {
        let playlist = AppPlaylist(name: "Undo")
        playlist.add([makeTrack(id: "1", title: "Before")])
        let set = playlist.createSet(named: "Middle")
        playlist.add([makeTrack(id: "2", title: "Inside Set")], to: set)
        playlist.add([makeTrack(id: "3", title: "After")])
        let removedEntry = try #require(
            playlist.orderedEntries.first(where: { $0.title == "Before" })
        )
        let originalID = removedEntry.id

        let snapshot = try #require(playlist.remove(removedEntry))
        let restored = try #require(playlist.restore(snapshot))

        #expect(restored.id == originalID)
        #expect(playlist.orderedEntries.map(\.title) == [
            "Before", "Inside Set", "After"
        ])
    }

    @Test
    func removedSetSongRestoresMetadataAndPosition() throws {
        let playlist = AppPlaylist(name: "Set Undo")
        let set = playlist.createSet(named: "Choices")
        playlist.add([
            makeTrack(id: "1", title: "One"),
            makeTrack(id: "2", title: "Two"),
            makeTrack(id: "3", title: "Three")
        ], to: set)
        let removedEntry = set.orderedEntries[1]

        let snapshot = try #require(playlist.remove(removedEntry))
        let restored = try #require(playlist.restore(snapshot))

        #expect(restored.title == "Two")
        #expect(restored.mediaPersistentID == "2")
        #expect(set.orderedEntries.map(\.title) == ["One", "Two", "Three"])
    }

    @Test
    func interactionCoordinatorRunsCurrentUndoOnce() {
        let interactions = InteractionCoordinator()
        var undoCount = 0

        interactions.showRemoval("Removed") {
            undoCount += 1
        }
        interactions.performUndo()
        interactions.performUndo()

        #expect(undoCount == 1)
        #expect(interactions.banner == nil)
    }

    @Test
    func selectionRequestsRequireSelectedSongs() {
        let interactions = InteractionCoordinator()
        interactions.beginSelection()
        interactions.requestAddSelection()
        #expect(interactions.addSelectionRequest == 0)

        interactions.updateSelection(count: 2, announceChange: false)
        interactions.requestAddSelection()
        #expect(interactions.addSelectionRequest == 1)
    }

    @Test
    func parentRandomKeepsSetSongsTogether() {
        let playlist = AppPlaylist(name: "Blocks")
        playlist.add([makeTrack(id: "1", title: "Loose")])
        let set = playlist.createSet(named: "Block")
        playlist.add([
            makeTrack(id: "2", title: "Set One"),
            makeTrack(id: "3", title: "Set Two")
        ], to: set)
        playlist.add([makeTrack(id: "4", title: "Loose Two")])
        playlist.orderMode = .random

        let planned = PlaylistQueuePlanner(randomIndex: { _ in 0 })
            .plannedEntries(for: playlist, startingAt: nil)
        let setIndices = planned.indices.filter { planned[$0].set?.id == set.id }

        #expect(setIndices.count == 2)
        #expect(setIndices[1] == setIndices[0] + 1)
    }

    @Test
    func searchNormalizationIgnoresCaseDiacriticsAndPunctuation() {
        #expect(SearchTextNormalizer.normalize("Beyoncé / AC/DC") == "beyonce ac dc")
    }

    @Test
    func searchAcceptsConservativeTranspositionTypos() {
        let artist = makeSearchDocument(
            id: "artist-beatles",
            category: .artist,
            title: "The Beatles",
            fields: [LibrarySearchField("The Beatles", weight: 14)]
        )

        let results = LibrarySearchEngine.search(
            query: "Bealtes",
            documents: [artist],
            scope: .all
        )

        #expect(results.results(for: .artist).map(\.document.title) == ["The Beatles"])
    }

    @Test
    func searchDoesNotFuzzyMatchVeryShortTerms() {
        let artist = makeSearchDocument(
            id: "artist-beatles",
            category: .artist,
            title: "The Beatles",
            fields: [LibrarySearchField("The Beatles", weight: 14)]
        )

        let results = LibrarySearchEngine.search(
            query: "bt",
            documents: [artist],
            scope: .all
        )

        #expect(results.isEmpty)
    }

    @Test
    func searchMatchesTokensAcrossMetadataInAnyOrder() {
        let song = makeSearchDocument(
            id: "song-yesterday",
            category: .song,
            title: "Yesterday",
            fields: [
                LibrarySearchField("Yesterday", weight: 14),
                LibrarySearchField("The Beatles", weight: 8)
            ]
        )

        let results = LibrarySearchEngine.search(
            query: "beatles yesterday",
            documents: [song],
            scope: .all
        )

        #expect(results.results(for: .song).map(\.document.title) == ["Yesterday"])
    }

    @Test
    func exactGroupingRanksAboveRelatedSongMetadata() {
        let artist = makeSearchDocument(
            id: "artist-beatles",
            category: .artist,
            title: "The Beatles",
            fields: [LibrarySearchField("Beatles", weight: 14)]
        )
        let song = makeSearchDocument(
            id: "song-yesterday",
            category: .song,
            title: "Yesterday",
            fields: [
                LibrarySearchField("Yesterday", weight: 14),
                LibrarySearchField("Beatles", weight: 8)
            ]
        )

        let results = LibrarySearchEngine.search(
            query: "Beatles",
            documents: [song, artist],
            scope: .all
        )

        #expect(results.topResults.first?.document.category == .artist)
    }

    @Test
    func searchScopesExcludeUnrelatedCategories() {
        let composer = makeSearchDocument(
            id: "composer-williams",
            category: .composer,
            title: "John Williams",
            fields: [LibrarySearchField("John Williams", weight: 14)]
        )
        let playlist = makeSearchDocument(
            id: "playlist-williams",
            category: .chauffeurPlaylist,
            title: "Williams Favorites",
            fields: [LibrarySearchField("Williams Favorites", weight: 14)]
        )

        let moreResults = LibrarySearchEngine.search(
            query: "Williams",
            documents: [composer, playlist],
            scope: .more
        )
        let playlistResults = LibrarySearchEngine.search(
            query: "Williams",
            documents: [composer, playlist],
            scope: .playlists
        )

        #expect(moreResults.results(for: .composer).count == 1)
        #expect(moreResults.results(for: .chauffeurPlaylist).isEmpty)
        #expect(playlistResults.results(for: .composer).isEmpty)
        #expect(playlistResults.results(for: .chauffeurPlaylist).count == 1)
    }

    @Test
    func recentSearchesAreNormalizedDeduplicatedAndCapped() {
        let suiteName = "LibrarySearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = LibrarySearchModel(defaults: defaults)

        for index in 0..<9 {
            model.query = "Query \(index)"
            model.recordCurrentQuery()
        }
        model.query = "  QUERY 8  "
        model.recordCurrentQuery()

        #expect(model.recentQueries.count == 8)
        #expect(model.recentQueries.first == "QUERY 8")
        #expect(model.recentQueries.filter {
            SearchTextNormalizer.normalize($0) == "query 8"
        }.count == 1)

        model.clearRecentQueries()
        #expect(model.recentQueries.isEmpty)
    }

    private func makeTrack(id: String, title: String) -> LibraryTrack {
        LibraryTrack(
            persistentID: id,
            title: title,
            artist: "Artist",
            albumTitle: "Album"
        )
    }

    private func makeSearchDocument(
        id: String,
        category: LibrarySearchCategory,
        title: String,
        fields: [LibrarySearchField]
    ) -> LibrarySearchDocument {
        LibrarySearchDocument(
            id: id,
            source: .track(id),
            category: category,
            title: title,
            subtitle: "",
            trackIDs: [],
            fields: fields
        )
    }
}
