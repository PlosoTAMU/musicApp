import Foundation

/// One word of a lyric line, for karaoke-style sweep.
struct LyricWord: Equatable {
    let timeMs: Int
    let text: String
}

/// One timestamped line from a synced (LRC) lyric source.
///
/// `timeMs` is FILE-relative: crops are playback windows over the full file
/// (see AudioPlayerManager — cropStartTime is a seek offset, never a trim),
/// so LRC timestamps line up with raw media time, not the cropped timeline.
/// Display mapping: fileTime = cropStart + player.currentTime.
///
/// `words`: exact when the source is enhanced LRC (<mm:ss.xx> word tags —
/// LRCLIB serves it for some tracks); otherwise estimated by spreading the
/// words evenly across the line's window. Estimated sweep is approximate by
/// design — close enough to read along, never claimed to be exact.
struct LyricLine: Identifiable, Equatable {
    let id: Int      // index in song order — stable ForEach/scrollTo anchor
    let timeMs: Int
    let text: String
    let words: [LyricWord]
}

/// Cross-device lyrics cache — users/{uid}/library/{trackId}/lyrics/current.
///
/// FIELD NAMES ARE THE CONTRACT — desktop/src/lyrics.ts mirrors this shape.
/// Lives in a subcollection (not on the library doc) so the desktop library
/// onSnapshot listener doesn't stream every song's lyrics at startup.
///
/// `offsetMs` shifts lyric timestamps against the file: a line is active when
/// fileTimeMs >= line.timeMs + offsetMs (positive offset = lyrics show later).
/// Whichever device nudges alignment writes it here; every device inherits it.
struct LyricsDoc: Codable, Equatable {
    var plain: String?       // plain-text lyrics (fallback when no synced)
    var synced: String?      // raw LRC text
    var source: String       // "lrclib"
    var offsetMs: Int
    var instrumental: Bool
    var fetchedAtMs: Int64   // epoch ms — drives the not-found retry window
    var notFound: Bool
}

/// (artist, track) query candidate for LRCLIB. Empty artist means the
/// candidate is only usable for fuzzy /api/search, not exact /api/get.
struct LyricsQuery: Equatable {
    let artist: String
    let track: String
}

enum LyricsQueryBuilder {

    /// Bracketed-segment junk words. "(Official Video)", "[4K]", "【MV】" are
    /// YouTube dressing, never part of the song identity LRCLIB knows —
    /// but "(Remix)"/"(Acoustic)" ARE identity, so only these get stripped.
    private static let junkWords = [
        "official", "video", "audio", "lyric", "visualizer", "visualiser",
        "hd", "hq", "4k", "8k", "mv", "m/v", "explicit", "remaster",
        "remastered", "color coded", "colour coded", "full version",
        "out now", "premiere", "music video", "sub español", "legendado",
    ]

    private static let bracketRE = try! NSRegularExpression(
        pattern: #"[\(\[【][^\(\)\[\]【】]*[\)\]】]"#)

    static func cleanTitle(_ raw: String) -> String {
        let ns = raw as NSString
        var result = ""
        var last = 0
        for m in bracketRE.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let seg = ns.substring(with: m.range).lowercased()
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !junkWords.contains(where: { seg.contains($0) }) {
                result += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Song (feat. X)" and "Song feat. X" → "Song" — LRCLIB track names
    /// usually omit the feature credit.
    static func stripFeat(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"(?i)\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]?"#,
            with: "", options: .regularExpression)
         .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespaces)
    }

    /// Ordered candidates, best guess first. Track names here are raw YouTube
    /// titles ("Artist - Title (Official Video)"); Spotify-sourced tracks also
    /// carry the cleaner oEmbed title, so that leads when present.
    static func candidates(name: String, spotifyTitle: String?) -> [LyricsQuery] {
        var out: [LyricsQuery] = []
        func add(_ artist: String, _ track: String) {
            let a = artist.trimmingCharacters(in: .whitespaces)
            let t = track.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            let q = LyricsQuery(artist: a, track: t)
            if !out.contains(q) { out.append(q) }
        }

        for raw in [spotifyTitle, name].compactMap({ $0 }) where !raw.isEmpty {
            let clean = cleanTitle(raw)
            let parts = clean.components(separatedBy: " - ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                let track = parts.dropFirst().joined(separator: " - ")
                add(parts[0], track)
                add(parts[0], stripFeat(track))
                // Reversed "Title - Artist" ordering happens in the wild.
                add(parts.last!, parts.dropLast().joined(separator: " - "))
            } else {
                add("", clean)
                add("", stripFeat(clean))
            }
        }
        return out
    }
}

enum LRCParser {

    // [mm:ss.xx] — also tolerates [mm:ss] and [mm:ss.xxx]; digits-only so
    // metadata tags like [ar:…] never match.
    private static let tagRE = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let offsetRE = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\]$"#, options: .caseInsensitive)
    // Enhanced-LRC word tags: <mm:ss.xx> inside the line body.
    private static let wordRE = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    private static func msFrom(_ ns: NSString, _ m: NSTextCheckingResult) -> Int {
        let mins = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let secs = Int(ns.substring(with: m.range(at: 2))) ?? 0
        var frac = 0
        if m.range(at: 3).location != NSNotFound {
            let f = ns.substring(with: m.range(at: 3))
            // ".5" = 500ms, ".55" = 550ms, ".555" = 555ms
            frac = (Int(f) ?? 0) * (f.count == 1 ? 100 : f.count == 2 ? 10 : 1)
        }
        return (mins * 60 + secs) * 1000 + frac
    }

    /// Parses LRC text into time-sorted lines. Handles multiple timestamps per
    /// line, the [offset:] header (LRC spec: positive = lyrics earlier), and
    /// enhanced-LRC <mm:ss.xx> word tags. Empty-text lines are kept — they
    /// mark instrumental gaps.
    static func parse(_ lrc: String) -> [LyricLine] {
        var stamped: [(ms: Int, raw: String)] = []
        var globalOffset = 0

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = offsetRE.firstMatch(in: line, range: full) {
                globalOffset = Int(ns.substring(with: m.range(at: 1))) ?? 0
                continue
            }

            // Only leading, contiguous tags count as timestamps for this line.
            var end = 0
            var times: [Int] = []
            for m in tagRE.matches(in: line, range: full) {
                guard m.range.location == end else { break }
                times.append(msFrom(ns, m))
                end = m.range.location + m.range.length
            }
            guard !times.isEmpty else { continue }

            let body = ns.substring(from: end)
            for t in times { stamped.append((max(0, t - globalOffset), body)) }
        }

        let sorted = stamped.sorted { $0.ms < $1.ms }
        return sorted.enumerated().map { idx, entry in
            let nextMs = idx + 1 < sorted.count ? sorted[idx + 1].ms : entry.ms + 5_000
            return makeLine(id: idx, startMs: entry.ms, raw: entry.raw,
                            nextMs: nextMs, offset: globalOffset)
        }
    }

    /// Word timing: exact from <…> tags when present, else even interpolation
    /// across the line window (finishing slightly early — natural phrasing).
    private static func makeLine(id: Int, startMs: Int, raw: String,
                                 nextMs: Int, offset: Int) -> LyricLine {
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        let tags = wordRE.matches(in: raw, range: full)

        if !tags.isEmpty {
            var words: [LyricWord] = []
            let lead = ns.substring(to: tags[0].range.location)
                .trimmingCharacters(in: .whitespaces)
            if !lead.isEmpty { words.append(LyricWord(timeMs: startMs, text: lead)) }
            for (i, m) in tags.enumerated() {
                let segStart = m.range.location + m.range.length
                let segEnd = i + 1 < tags.count ? tags[i + 1].range.location : ns.length
                let text = ns.substring(with: NSRange(location: segStart, length: segEnd - segStart))
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    words.append(LyricWord(timeMs: max(0, msFrom(ns, m) - offset), text: text))
                }
            }
            return LyricLine(id: id, timeMs: startMs,
                             text: words.map(\.text).joined(separator: " "),
                             words: words)
        }

        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count > 1 else {
            return LyricLine(id: id, timeMs: startMs, text: text,
                             words: text.isEmpty ? [] : [LyricWord(timeMs: startMs, text: text)])
        }
        let window = min(max(nextMs - startMs, 600), 12_000)
        let step = Double(window) * 0.92 / Double(parts.count)
        let words = parts.enumerated().map {
            LyricWord(timeMs: startMs + Int(Double($0.offset) * step), text: $0.element)
        }
        return LyricLine(id: id, timeMs: startMs, text: text, words: words)
    }
}
