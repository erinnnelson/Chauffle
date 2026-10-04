import AVFAudio
import Foundation
import MediaPlayer
import Observation

protocol PlaybackControlling: AnyObject {
    var nowPlaying: LibraryTrack? { get }
    var isPlaying: Bool { get }

    func play(
        tracks: [LibraryTrack],
        startingAt trackID: LibraryTrack.ID?,
        mediaLibrary: MediaLibraryService
    )
    func play(
        playlist: AppPlaylist,
        startingAt entryID: UUID?,
        mediaLibrary: MediaLibraryService
    )
    func togglePlayPause()
    func skipToNext()
    func skipToPrevious()
    func seek(to time: TimeInterval)
}

private struct PlaybackQueueContext {
    let entryID: UUID?
    let playlistName: String?
    let setName: String?
}

@MainActor
@Observable
final class PlaybackController: PlaybackControlling {
    private(set) var nowPlaying: LibraryTrack?
    private(set) var isPlaying = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var activePlaylistName: String?
    private(set) var activeSetName: String?
    private(set) var errorMessage: String?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let queuePlanner = PlaylistQueuePlanner()
    private var notificationTasks: [Task<Void, Never>] = []
    private var progressTask: Task<Void, Never>?
    private var activePlaylist: AppPlaylist?
    private var activeMediaLibrary: MediaLibraryService?
    private var queueContexts: [PlaybackQueueContext] = []
    private var nextCycleBoundary: Int?
    private var pendingPlaylistUpdate = false

    init() {
        player.beginGeneratingPlaybackNotifications()
        observePlaybackNotifications()
        startProgressUpdates()
        refreshState()
    }

    func play(
        tracks: [LibraryTrack],
        startingAt trackID: LibraryTrack.ID? = nil,
        mediaLibrary: MediaLibraryService
    ) {
        activePlaylist = nil
        activeMediaLibrary = mediaLibrary
        activePlaylistName = nil
        activeSetName = nil
        queueContexts = tracks.map { _ in
            PlaybackQueueContext(entryID: nil, playlistName: nil, setName: nil)
        }
        nextCycleBoundary = nil

        setQueue(
            tracks: tracks,
            startingAt: trackID,
            mediaLibrary: mediaLibrary
        )
    }

    func play(
        playlist: AppPlaylist,
        startingAt entryID: UUID? = nil,
        mediaLibrary: MediaLibraryService
    ) {
        activePlaylist = playlist
        activeMediaLibrary = mediaLibrary
        pendingPlaylistUpdate = false

        let firstCycle = queuePlanner.plannedEntries(
            for: playlist,
            startingAt: entryID
        )
        let firstPlayable = playableEntries(
            from: firstCycle,
            playlist: playlist,
            mediaLibrary: mediaLibrary
        )
        var playable = firstPlayable

        if playlist.isLooping {
            let nextCycle = queuePlanner.plannedEntries(for: playlist, startingAt: nil)
            playable += playableEntries(
                from: nextCycle,
                playlist: playlist,
                mediaLibrary: mediaLibrary
            )
            nextCycleBoundary = firstPlayable.count
        } else {
            nextCycleBoundary = nil
        }

        queueContexts = playable.map(\.1)
        setQueue(
            tracks: playable.map(\.0),
            startingAt: nil,
            mediaLibrary: mediaLibrary
        )
    }

    func playlistDidChange(_ playlist: AppPlaylist) {
        guard activePlaylist?.id == playlist.id else { return }
        pendingPlaylistUpdate = true
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        refreshState()
    }

    func skipToNext() {
        player.skipToNextItem()
        refreshState()
    }

    func skipToPrevious() {
        if elapsedTime > 3 {
            player.skipToBeginning()
        } else {
            player.skipToPreviousItem()
        }
        refreshState()
    }

    func seek(to time: TimeInterval) {
        player.currentPlaybackTime = min(max(time, 0), duration)
        refreshState()
    }

    private func setQueue(
        tracks: [LibraryTrack],
        startingAt trackID: LibraryTrack.ID?,
        mediaLibrary: MediaLibraryService
    ) {
        let items = mediaLibrary.mediaItems(for: tracks)
        guard !items.isEmpty else {
            errorMessage = String(localized: "No selected songs are currently playable.")
            return
        }

        configureAudioSession()
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(
            itemCollection: MPMediaItemCollection(items: items)
        )

        if let trackID,
           let startItem = items.first(where: { String($0.persistentID) == trackID }) {
            descriptor.startItem = startItem
        }

        errorMessage = nil
        player.repeatMode = .none
        player.shuffleMode = .off
        player.setQueue(with: descriptor)
        player.prepareToPlay()
        player.play()
        refreshState()
    }

    private func appendNextCycleIfNeeded() {
        guard let playlist = activePlaylist,
              playlist.isLooping,
              let mediaLibrary = activeMediaLibrary,
              let boundary = nextCycleBoundary,
              player.indexOfNowPlayingItem >= boundary else {
            return
        }

        let planned = queuePlanner.plannedEntries(for: playlist, startingAt: nil)
        let playable = playableEntries(
            from: planned,
            playlist: playlist,
            mediaLibrary: mediaLibrary
        )
        let items = mediaLibrary.mediaItems(for: playable.map(\.0))
        guard !items.isEmpty else { return }

        nextCycleBoundary = queueContexts.count
        queueContexts.append(contentsOf: playable.map(\.1))
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(
            itemCollection: MPMediaItemCollection(items: items)
        )
        player.append(descriptor)
    }

    private func rebuildQueueAfterPlaylistChange() {
        guard pendingPlaylistUpdate,
              let playlist = activePlaylist,
              let mediaLibrary = activeMediaLibrary else {
            return
        }

        pendingPlaylistUpdate = false
        let currentIndex = player.indexOfNowPlayingItem
        let currentEntryID = queueContexts.indices.contains(currentIndex)
            ? queueContexts[currentIndex].entryID
            : nil
        let playbackTime = player.currentPlaybackTime

        let currentCycle = queuePlanner.plannedEntries(
            for: playlist,
            startingAt: currentEntryID
        )
        let currentPlayable = playableEntries(
            from: currentCycle,
            playlist: playlist,
            mediaLibrary: mediaLibrary
        )
        var playable = currentPlayable

        if playlist.isLooping {
            let nextCycle = queuePlanner.plannedEntries(for: playlist, startingAt: nil)
            playable += playableEntries(
                from: nextCycle,
                playlist: playlist,
                mediaLibrary: mediaLibrary
            )
            nextCycleBoundary = currentPlayable.count
        } else {
            nextCycleBoundary = nil
        }

        queueContexts = playable.map(\.1)
        setQueue(
            tracks: playable.map(\.0),
            startingAt: nil,
            mediaLibrary: mediaLibrary
        )
        player.currentPlaybackTime = playbackTime
    }

    private func playableEntries(
        from planned: [PlannedPlaylistEntry],
        playlist: AppPlaylist,
        mediaLibrary: MediaLibraryService
    ) -> [(LibraryTrack, PlaybackQueueContext)] {
        planned.compactMap { plannedEntry in
            guard let track = mediaLibrary.resolvedTrack(for: plannedEntry.entry) else {
                return nil
            }
            return (
                track,
                PlaybackQueueContext(
                    entryID: plannedEntry.entry.id,
                    playlistName: playlist.name,
                    setName: plannedEntry.set?.name
                )
            )
        }
    }

    private func observePlaybackNotifications() {
        let names: [Notification.Name] = [
            .MPMusicPlayerControllerPlaybackStateDidChange,
            .MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerQueueDidChange
        ]

        notificationTasks = names.map { name in
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard !Task.isCancelled else { return }
                    self?.refreshState()
                    if name == .MPMusicPlayerControllerNowPlayingItemDidChange {
                        if self?.pendingPlaylistUpdate == true {
                            self?.rebuildQueueAfterPlaylistChange()
                        } else {
                            self?.appendNextCycleIfNeeded()
                        }
                    }
                }
            }
        }
    }

    private func startProgressUpdates() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshProgress()
            }
        }
    }

    private func refreshState() {
        isPlaying = player.playbackState == .playing

        if let item = player.nowPlayingItem {
            nowPlaying = LibraryTrack(item: item)
            duration = item.playbackDuration
            updateQueueContext()
        } else {
            nowPlaying = nil
            duration = 0
            activePlaylistName = nil
            activeSetName = nil
        }
        refreshProgress()
    }

    private func refreshProgress() {
        guard player.nowPlayingItem != nil else {
            elapsedTime = 0
            return
        }
        elapsedTime = max(player.currentPlaybackTime, 0)
    }

    private func updateQueueContext() {
        let index = player.indexOfNowPlayingItem
        guard queueContexts.indices.contains(index) else {
            activePlaylistName = activePlaylist?.name
            activeSetName = nil
            return
        }
        activePlaylistName = queueContexts[index].playlistName
        activeSetName = queueContexts[index].setName
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
