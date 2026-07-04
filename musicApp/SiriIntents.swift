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
    private var pendingTrackID: UUID?

    private init() {}

    /// Called from ContentView.onAppear once the managers exist.
    @MainActor
    func attach(audioPlayer: AudioPlayerManager, downloadManager: DownloadManager) {
        self.audioPlayer = audioPlayer
        self.downloadManager = downloadManager
        fulfillPendingIfNeeded()
    }

    /// Plays a specific download by id. Returns true if playback started now,
    /// false if the app wasn't ready (the request is then queued for launch).
    @discardableResult
    @MainActor
    func requestPlay(trackID: UUID) -> Bool {
        guard let dm = downloadManager, let ap = audioPlayer else {
            pendingTrackID = trackID
            return false
        }
        return play(trackID: trackID, downloadManager: dm, audioPlayer: ap)
    }

    @MainActor
    private func fulfillPendingIfNeeded() {
        guard let id = pendingTrackID,
              let dm = downloadManager,
              let ap = audioPlayer else { return }

        if play(trackID: id, downloadManager: dm, audioPlayer: ap) {
            pendingTrackID = nil
        } else {
            // Library may still be loading on a cold launch — retry once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      let id = self.pendingTrackID,
                      let dm = self.downloadManager,
                      let ap = self.audioPlayer else { return }
                _ = self.play(trackID: id, downloadManager: dm, audioPlayer: ap)
                self.pendingTrackID = nil
            }
        }
    }

    @MainActor
    @discardableResult
    private func play(trackID: UUID, downloadManager: DownloadManager, audioPlayer: AudioPlayerManager) -> Bool {
        guard let match = downloadManager.getDownload(byID: trackID) else { return false }

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
}

// MARK: - Library reader
//
// Reads the song library straight from Documents/downloads.json so the
// entity query works even when the app process isn't running (which is the
// normal case when Siri resolves a shortcut).
enum SongLibrary {
    static func allSongs() -> [SongEntity] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("downloads.json")
        guard let data = try? Data(contentsOf: url),
              let downloads = try? JSONDecoder().decode([Download].self, from: data) else {
            return []
        }
        return downloads
            .filter { !$0.pendingDeletion }
            // Use a SPEAKABLE title so Siri's grammar matches natural phrasing.
            // The raw YouTube name ("Faded (Official Music Video) [4K]") is almost
            // impossible to say verbatim; playback still uses the id, so the real
            // file/name is unaffected.
            .map { SongEntity(id: $0.id, name: speakableTitle($0.name)) }
    }

    /// Strips the noise that makes spoken matching fail: bracketed/parenthesized
    /// segments and common tags ("official video", "lyrics", "HD", …).
    static func speakableTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        let noise = [
            "official music video", "official lyric video", "official video",
            "official audio", "lyric video", "lyrics", "visualizer",
            "audio", "hd", "4k", "mv", "m/v"
        ]
        for n in noise {
            // Word-boundary match — a plain substring replace mangled titles
            // ("audio" inside "Audiophile" → "phile"), and mangled entity
            // names are unmatchable when spoken.
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: n))\\b"
            s = s.replacingOccurrences(of: pattern, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·"))
        return s.isEmpty ? raw : s
    }
}

// MARK: - Song entity
//
// Exposing songs as an AppEntity (instead of a free-form String parameter)
// is what lets Siri resolve a spoken title like "play Blinding Lights" by
// matching it against the real library. Free-form string parameters in App
// Shortcut phrases are why Siri answered "hasn't added support for that".
@available(iOS 16.0, *)
struct SongEntity: AppEntity, Identifiable {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static var defaultQuery = SongEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

@available(iOS 16.0, *)
struct SongEntityQuery: EntityQuery, EntityStringQuery {
    // Resolve by entity id (used internally by the system).
    func entities(for identifiers: [UUID]) async throws -> [SongEntity] {
        let all = SongLibrary.allSongs()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }

    // Resolve by the spoken/typed string — the important one for Siri.
    func entities(matching string: String) async throws -> [SongEntity] {
        let q = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = SongLibrary.allSongs()
        guard !q.isEmpty else { return all }

        // Exact, then substring, then word-overlap ranking.
        if let exact = all.first(where: { $0.name.lowercased() == q }) {
            return [exact]
        }
        let substring = all.filter {
            let n = $0.name.lowercased()
            return n.contains(q) || q.contains(n)
        }
        if !substring.isEmpty { return substring }

        let qTokens = Set(q.split(separator: " ").map(String.init))
        let scored = all
            .map { song -> (SongEntity, Int) in
                let nTokens = Set(song.name.lowercased().split(separator: " ").map(String.init))
                return (song, qTokens.intersection(nTokens).count)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        return scored
    }

    // Shown as suggestions in the Shortcuts app.
    func suggestedEntities() async throws -> [SongEntity] {
        SongLibrary.allSongs()
    }
}

// MARK: - Play Song intent
//
// Drives "Hey Siri, play <song> in <app name>". The song parameter is a
// SongEntity, so Siri matches the spoken title against the library above.
@available(iOS 16.0, *)
struct PlaySongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Song"
    static var description = IntentDescription("Plays a song from your library by name.")

    // Bring the app to the foreground so playback is visible and the player
    // is guaranteed to be running.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Song")
    var song: SongEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = SiriPlaybackBridge.shared.requestPlay(trackID: song.id)
        if started {
            return .result(dialog: "Playing \(song.name)")
        } else {
            // App was cold-launched; the request is queued and will play as
            // soon as the library finishes loading.
            return .result(dialog: "Opening to play \(song.name)")
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
                "Play \(\.$song) in \(.applicationName)",
                "Play \(\.$song) on \(.applicationName)",
                "\(.applicationName) play \(\.$song)",
                "Play \(\.$song) with \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "play.circle.fill"
        )
    }
}
