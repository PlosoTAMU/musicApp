import Foundation

enum DownloadSource: String, Codable {
    case youtube
    case spotify
    case folder
}

struct Download: Identifiable, Codable {
    let id: UUID
    let name: String
    let url: URL
    var thumbnailPath: String?
    var videoID: String?
    var source: DownloadSource
    var originalURL: String?  // ✅ ADD THIS - store the original download URL
    var cropStartTime: Double?
    var cropEndTime: Double?
    var pendingDeletion: Bool = false
    /// Display folder from the cloud doc (desktop is the folder authority);
    /// iOS never moves files — this only groups/labels them in the UI.
    var folderOverride: String?
    // Behind-the-scenes metadata shown in Song Info
    var spotifyTitle: String?       // Title returned by Spotify oEmbed (Spotify tracks only)
    var youtubeSearchQuery: String? // Query used to find the YouTube video
    var youtubeURL: String?         // Final YouTube URL that was downloaded
    // Set when a thumbnail fetch exhausts all URLs/attempts, so a
    // permanently-unfetchable thumbnail isn't retried on every cold launch —
    // see DownloadManager.validateAndFixThumbnails().
    var thumbnailFetchFailedAtMs: Int64?


    // ⚡ PERF: Cache the thumbnails directory path once instead of calling
    // FileManager.default.urls(for:in:) on every row render in the list
    private static let thumbnailsDirectory: String = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Thumbnails").path
    }()
    
    /// The path the RECORD points at — no existence check, no fallback. This
    /// is the bookkeeping view (what to delete, what to migrate). Display code
    /// must use `artworkPath` instead; reading this one for display is how the
    /// mini player, Now Playing, and the Up Next strip each ended up resolving
    /// artwork differently and disagreeing with one another.
    var resolvedThumbnailPath: String? {
        guard let filename = thumbnailPath else { return nil }

        let justFilename = filename.contains("/") ? (filename as NSString).lastPathComponent : filename
        return (Download.thumbnailsDirectory as NSString).appendingPathComponent(justFilename)
    }

    /// THE artwork resolver — the one answer every surface shows (list rows,
    /// Up Next, mini player, Now Playing art + backdrop, playlist covers).
    ///
    /// Order, and why:
    ///  1. `<videoID>.jpg` when it exists. Same videoID ⇒ same artwork, so
    ///     this file can never be another song's, and it wins over whatever
    ///     the record still names — a record migrated from the legacy scheme
    ///     keeps pointing at `<audio filename>.jpg` until the boot heal
    ///     re-points it, and that legacy key is reusable (a re-download or a
    ///     rename could leave a DIFFERENT song's art under it).
    ///  2. The record's own file, if it is actually on disk.
    ///  3. The audio-URL lookup (metadata sidecar → videoID key, then the
    ///     legacy key), for records with no videoID or nothing stored yet.
    ///
    /// Every step is existence-checked, so a stale filename in the record
    /// (file purged, heal not landed) degrades to the next source instead of
    /// a placeholder while the same song shows art one screen over.
    var artworkPath: String? {
        let fm = FileManager.default
        if let videoID, !videoID.isEmpty {
            let keyed = (Download.thumbnailsDirectory as NSString).appendingPathComponent("\(videoID).jpg")
            if fm.fileExists(atPath: keyed) { return keyed }
        }
        if let stored = resolvedThumbnailPath, fm.fileExists(atPath: stored) { return stored }
        return EmbeddedPython.shared.getThumbnailPath(for: url)?.path
    }
    
    init(id: UUID = UUID(), name: String, url: URL, thumbnailPath: String? = nil, videoID: String? = nil, source: DownloadSource = .youtube, originalURL: String? = nil, cropStartTime: Double? = nil, cropEndTime: Double? = nil, spotifyTitle: String? = nil, youtubeSearchQuery: String? = nil, youtubeURL: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        if let path = thumbnailPath {
            self.thumbnailPath = (path as NSString).lastPathComponent
        } else {
            self.thumbnailPath = nil
        }
        self.videoID = videoID
        self.source = source
        self.originalURL = originalURL  // ✅ ADD THIS
        self.cropStartTime = cropStartTime
        self.cropEndTime = cropEndTime
        self.pendingDeletion = false
        self.spotifyTitle = spotifyTitle
        self.youtubeSearchQuery = youtubeSearchQuery
        self.youtubeURL = youtubeURL
    }
}

struct ActiveDownload: Identifiable, Equatable {
    let id: UUID
    let videoID: String
    var title: String // FIXED: Changed from `let` to `var` so title can be updated
    var progress: Double
    
    // FIXED: Explicit Equatable conformance for proper SwiftUI diffing
    static func == (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.id == rhs.id && lhs.videoID == rhs.videoID && lhs.title == rhs.title && lhs.progress == rhs.progress
    }
}

struct FailedDownload: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let source: DownloadSource
    let error: String
    let timestamp: Date
}