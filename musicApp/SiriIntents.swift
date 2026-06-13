import Foundation
import AppIntents

// MARK: - Playback bridge
//
// App Intents run in their own execution context, so they can't see the
// @StateObject AudioPlayerManager that ContentView owns. This singleton is
// the bridge: ContentView hands it live references in `onAppear`, and the
// intent calls into it. If a request arrives during a cold launch (before
// ContentView has appeared), it's stored and fulfilled as soon as the app
// finishes wiring up.
final class SiriPlaybackBridge {
    static let shared = SiriPlaybackBridge()
    
    weak var audioPlayer: AudioPlayerManager?
    weak var downloadManager: DownloadManager?
    private var pendingQuery: String?
    
    private init() {}
    
    /// Called from ContentView.onAppear once the managers exist.
    @MainActor
    func attach(audioPlayer: AudioPlayerManager, downloadManager: DownloadManager) {
        self.audioPlayer = audioPlayer
        self.downloadManager = downloadManager
        fulfillPendingIfNeeded()
    }
    
    /// Attempts to play a song matching `query`. Returns true if playback
    /// started now; false if the app wasn't ready yet (the request is then
    /// queued and played on launch).
    @discardableResult
    @MainActor
    func requestPlay(query: String) -> Bool {
        guard let dm = downloadManager, let ap = audioPlayer else {
            pendingQuery = query
            return false
        }
        return play(query: query, downloadManager: dm, audioPlayer: ap)
    }
    
    @MainActor
    private func fulfillPendingIfNeeded() {
        guard let query = pendingQuery,
              let dm = downloadManager,
              let ap = audioPlayer else { return }
        
        if play(query: query, downloadManager: dm, audioPlayer: ap) {
            pendingQuery = nil
        } else {
            // Library may still be loading on a cold launch — retry once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      let query = self.pendingQuery,
                      let dm = self.downloadManager,
                      let ap = self.audioPlayer else { return }
                _ = self.play(query: query, downloadManager: dm, audioPlayer: ap)
                self.pendingQuery = nil
            }
        }
    }
    
    @MainActor
    @discardableResult
    private func play(query: String, downloadManager: DownloadManager, audioPlayer: AudioPlayerManager) -> Bool {
        guard let match = bestMatch(for: query, in: downloadManager.downloads) else {
            return false
        }
        
        let folderName: String
        switch match.source {
        case .youtube: folderName = "YouTube"
        case .spotify: folderName = "Spotify"
        case .folder:  folderName = "Files"
        }
        
        let track = Track(
            id: match.id,
            name: match.name,
            url: match.url,
            folderName: folderName,
            cropStartTime: match.cropStartTime,
            cropEndTime: match.cropEndTime
        )
        audioPlayer.play(track)
        return true
    }
    
    /// The name of the song that best matches a spoken query, or nil.
    var lastMatchedName: String?
    
    private func bestMatch(for query: String, in downloads: [Download]) -> Download? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            lastMatchedName = downloads.first?.name
            return downloads.first
        }
        
        // 1. Exact name match.
        if let exact = downloads.first(where: { $0.name.lowercased() == q }) {
            lastMatchedName = exact.name
            return exact
        }
        
        // 2. Substring match either direction.
        if let contains = downloads.first(where: {
            let name = $0.name.lowercased()
            return name.contains(q) || q.contains(name)
        }) {
            lastMatchedName = contains.name
            return contains
        }
        
        // 3. Highest word-overlap score.
        let queryTokens = Set(q.split(separator: " ").map(String.init))
        var best: (download: Download, score: Int)?
        for download in downloads {
            let nameTokens = Set(download.name.lowercased().split(separator: " ").map(String.init))
            let score = queryTokens.intersection(nameTokens).count
            if score > 0, best == nil || score > best!.score {
                best = (download, score)
            }
        }
        lastMatchedName = best?.download.name
        return best?.download
    }
}

// MARK: - Play Song intent
//
// Drives "Hey Siri, play <song> in <app name>". The song title is a free
// string parameter so any track in the library can be requested by voice.
@available(iOS 16.0, *)
struct PlaySongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Song"
    static var description = IntentDescription("Plays a downloaded song by name.")
    
    // Bring the app to the foreground so playback is visible and the player
    // is guaranteed to be running.
    static var openAppWhenRun: Bool = true
    
    @Parameter(title: "Song", requestValueDialog: "Which song?")
    var songName: String
    
    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$songName)")
    }
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = SiriPlaybackBridge.shared.requestPlay(query: songName)
        
        if started {
            let name = SiriPlaybackBridge.shared.lastMatchedName ?? songName
            return .result(dialog: "Playing \(name)")
        } else {
            // App was cold-launched; the request is queued and will play
            // as soon as the library finishes loading.
            return .result(dialog: "Opening to play \(songName)")
        }
    }
}

// MARK: - App Shortcuts
//
// Registers spoken phrases automatically the first time the app is run, so
// the user doesn't have to set anything up in the Shortcuts app. Apple
// requires the app name token in every phrase.
@available(iOS 16.0, *)
struct MusicAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play \(\.$songName) in \(.applicationName)",
                "Play \(\.$songName) on \(.applicationName)",
                "\(.applicationName) play \(\.$songName)",
                "Play \(\.$songName) with \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "play.circle.fill"
        )
    }
}
