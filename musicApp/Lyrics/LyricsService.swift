import Foundation
import AVFoundation
import FirebaseAuth
import FirebaseFirestore

/// Fetches, caches, and serves lyrics for the playing track.
///
/// Lookup order: memory → disk (Documents/Lyrics/{id}.json) → Firestore
/// (users/{uid}/library/{id}/lyrics/current — the shared home cache) → LRCLIB.
/// Whichever device resolves a track first writes the doc; every other device
/// then reads the verdict instead of re-querying LRCLIB.
///
/// Duration guard: fuzzy /api/search hits are only accepted when the record's
/// duration is within ±5s of the FULL file duration (crops are playback
/// windows, so the file length is the canonical one). This is what keeps
/// remix/live/sped-up versions from matching the studio original's lyrics.
@MainActor
final class LyricsService: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case synced(lines: [LyricLine], offsetMs: Int)
        case plain(String)
        case unavailable(reason: String)
    }

    @Published private(set) var state: State = .idle
    private(set) var trackID: UUID?

    private var memory: [UUID: LyricsDoc] = [:]
    private var fetchTask: Task<Void, Never>?

    private static let notFoundRetryMs: Int64 = 7 * 24 * 3600 * 1000
    private static let userAgent = "Pulsor/1.0 (music app lyrics)"

    // MARK: - Entry

    func load(track: Track, download: Download?, force: Bool = false) {
        if !force, trackID == track.id, state != .idle { return }
        fetchTask?.cancel()
        trackID = track.id
        state = .loading
        let requested = track.id
        fetchTask = Task { [weak self] in
            await self?.resolve(track: track, download: download,
                                requested: requested, force: force)
        }
    }

    /// Manual alignment nudge — persisted locally and to Firestore so every
    /// device inherits the corrected offset.
    func nudgeOffset(by deltaMs: Int) {
        guard let id = trackID, case .synced(let lines, let offset) = state else { return }
        let newOffset = offset + deltaMs
        state = .synced(lines: lines, offsetMs: newOffset)
        var doc = memory[id] ?? LyricsDoc(plain: nil, synced: nil, source: "lrclib",
                                          offsetMs: 0, instrumental: false,
                                          fetchedAtMs: Self.nowMs(), notFound: false)
        doc.offsetMs = newOffset
        memory[id] = doc
        Self.writeDisk(id, doc)
        // Merge-write ONLY the offset — a full setData from a partial in-memory
        // doc could clobber the synced lyrics for every device in the home.
        Task { [weak self] in
            guard let ref = self?.lyricsRef(id) else { return }
            try? await ref.setData(["offsetMs": newOffset], merge: true)
        }
    }

    // MARK: - Resolution pipeline

    private func resolve(track: Track, download: Download?, requested: UUID, force: Bool) async {
        if !force {
            if let doc = memory[track.id] ?? Self.readDisk(track.id) {
                memory[track.id] = doc
                if !(doc.notFound && Self.expired(doc)) {
                    apply(doc, for: requested)
                    return
                }
            }
            if let doc = await readFirestore(track.id) {
                memory[track.id] = doc
                Self.writeDisk(track.id, doc)
                if !(doc.notFound && Self.expired(doc)) {
                    apply(doc, for: requested)
                    return
                }
            }
        }

        let doc = await fetchFromLRCLIB(track: track, download: download)
        guard !Task.isCancelled else { return }
        memory[track.id] = doc
        Self.writeDisk(track.id, doc)
        await writeFirestore(track.id, doc)
        apply(doc, for: requested)
    }

    private func apply(_ doc: LyricsDoc, for requested: UUID) {
        guard requested == trackID else { return }  // track changed mid-fetch
        if doc.instrumental {
            state = .unavailable(reason: "Instrumental track")
            return
        }
        if let lrc = doc.synced, !lrc.isEmpty {
            let lines = LRCParser.parse(lrc)
            if !lines.isEmpty {
                state = .synced(lines: lines, offsetMs: doc.offsetMs)
                return
            }
        }
        if let plain = doc.plain, !plain.isEmpty {
            state = .plain(plain)
            return
        }
        state = .unavailable(reason: "No lyrics found")
    }

    // MARK: - LRCLIB

    private struct LRCLIBRecord: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private func fetchFromLRCLIB(track: Track, download: Download?) async -> LyricsDoc {
        let dur = Self.fileDurationSec(track)
        let cands = LyricsQueryBuilder.candidates(name: track.name,
                                                  spotifyTitle: download?.spotifyTitle)

        var hit: LRCLIBRecord?
        for q in cands where !q.artist.isEmpty {
            if Task.isCancelled { break }
            if let rec = await apiGet(q, durationSec: dur), Self.durationOK(rec, dur) {
                hit = rec
                break
            }
        }

        // Fuzzy fallback is only safe behind the duration guard — with an
        // unreadable file duration a top search hit is a coin flip, so skip.
        if hit == nil, dur != nil {
            for q in cands.prefix(2) {
                if Task.isCancelled { break }
                let query = q.artist.isEmpty ? q.track : "\(q.artist) \(q.track)"
                if let rec = pickBest(await apiSearch(query), durationSec: dur) {
                    hit = rec
                    break
                }
            }
        }

        let now = Self.nowMs()
        let synced = hit?.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = hit?.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instrumental = hit?.instrumental ?? false
        let found = instrumental || synced?.isEmpty == false || plain?.isEmpty == false
        return LyricsDoc(plain: (plain?.isEmpty == false) ? plain : nil,
                         synced: (synced?.isEmpty == false) ? synced : nil,
                         source: "lrclib",
                         offsetMs: 0,
                         instrumental: instrumental,
                         fetchedAtMs: now,
                         notFound: !found)
    }

    private func apiGet(_ q: LyricsQuery, durationSec: Int?) async -> LRCLIBRecord? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "artist_name", value: q.artist),
                     URLQueryItem(name: "track_name", value: q.track)]
        if let d = durationSec { items.append(URLQueryItem(name: "duration", value: String(d))) }
        comps.queryItems = items
        guard let data = await request(comps.url) else { return nil }
        return try? JSONDecoder().decode(LRCLIBRecord.self, from: data)
    }

    private func apiSearch(_ query: String) async -> [LRCLIBRecord] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let data = await request(comps.url) else { return [] }
        return (try? JSONDecoder().decode([LRCLIBRecord].self, from: data)) ?? []
    }

    private func request(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func pickBest(_ recs: [LRCLIBRecord], durationSec: Int?) -> LRCLIBRecord? {
        func score(_ r: LRCLIBRecord) -> Int {
            (r.syncedLyrics?.isEmpty == false ? 2 : 0) +
            (r.plainLyrics?.isEmpty == false ? 1 : 0)
        }
        return recs
            .filter { score($0) > 0 || $0.instrumental == true }
            .filter { Self.durationOK($0, durationSec, strict: true) }
            .max { score($0) < score($1) }
    }

    /// strict: records with no duration are rejected (fuzzy search results);
    /// non-strict: /api/get already matched server-side, missing duration is OK.
    private static func durationOK(_ rec: LRCLIBRecord, _ fileSec: Int?, strict: Bool = false) -> Bool {
        guard let fileSec else { return !strict }
        guard let recDur = rec.duration else { return !strict }
        return abs(recDur - Double(fileSec)) <= 5
    }

    /// FULL file duration — crop times are a playback window, never a trim,
    /// so the raw file length is what LRCLIB's canonical duration matches.
    private static func fileDurationSec(_ track: Track) -> Int? {
        guard let url = track.resolvedURL() else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let dur = Double(f.length) / f.processingFormat.sampleRate
        return (dur.isFinite && dur > 0) ? Int(dur.rounded()) : nil
    }

    // MARK: - Firestore cache (shared across the home's devices)

    private func lyricsRef(_ id: UUID) -> DocumentReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return Firestore.firestore()
            .collection("users").document(uid)
            .collection("library").document(id.uuidString)
            .collection("lyrics").document("current")
    }

    private func readFirestore(_ id: UUID) async -> LyricsDoc? {
        guard let ref = lyricsRef(id),
              let snap = try? await ref.getDocument(),
              snap.exists, let d = snap.data() else { return nil }
        return LyricsDoc(
            plain: d["plain"] as? String,
            synced: d["synced"] as? String,
            source: d["source"] as? String ?? "lrclib",
            offsetMs: (d["offsetMs"] as? NSNumber)?.intValue ?? 0,
            instrumental: d["instrumental"] as? Bool ?? false,
            fetchedAtMs: (d["fetchedAtMs"] as? NSNumber)?.int64Value ?? 0,
            notFound: d["notFound"] as? Bool ?? false)
    }

    private func writeFirestore(_ id: UUID, _ doc: LyricsDoc) async {
        guard let ref = lyricsRef(id) else { return }
        var data: [String: Any] = [
            "source": doc.source,
            "offsetMs": doc.offsetMs,
            "instrumental": doc.instrumental,
            "fetchedAtMs": doc.fetchedAtMs,
            "notFound": doc.notFound,
        ]
        if let p = doc.plain { data["plain"] = p }
        if let s = doc.synced { data["synced"] = s }
        try? await ref.setData(data)
    }

    // MARK: - Disk cache

    private static let cacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskURL(_ id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString).json")
    }

    private static func readDisk(_ id: UUID) -> LyricsDoc? {
        guard let data = try? Data(contentsOf: diskURL(id)) else { return nil }
        return try? JSONDecoder().decode(LyricsDoc.self, from: data)
    }

    private static func writeDisk(_ id: UUID, _ doc: LyricsDoc) {
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: diskURL(id), options: .atomic)
        }
    }

    private static func expired(_ doc: LyricsDoc) -> Bool {
        nowMs() - doc.fetchedAtMs > notFoundRetryMs
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
