import SwiftUI

/// Lyrics sheet for the Now Playing screen.
///
/// LyricLine timestamps are file-relative; the player's currentTime is
/// crop-relative, so the mapping is fileTime = cropStart + currentTime.
/// Tapping a line seeks there (crop-clamped). The Sync −/+ buttons nudge the
/// shared offsetMs when the downloaded version doesn't line up with LRCLIB's
/// canonical timing (music-video intros, alternate masters).
struct LyricsView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var lyrics: LyricsService

    @State private var lastScrolledIndex: Int? = nil
    @State private var userScrolledAt: Date? = nil

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .onAppear { loadCurrent() }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            lastScrolledIndex = nil
            userScrolledAt = nil
            loadCurrent()
        }
    }

    private func loadCurrent(force: Bool = false) {
        guard let track = audioPlayer.currentTrack else { return }
        lyrics.load(track: track,
                    download: downloadManager.getDownload(byID: track.id),
                    force: force)
    }

    /// Current position in FILE time (ms) — what LRC timestamps refer to.
    private var fileTimeMs: Int {
        let cropStart = audioPlayer.currentTrack?.cropStartTime ?? 0
        return Int((cropStart + audioPlayer.currentTime) * 1000)
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 2) {
            Text(audioPlayer.currentTrack?.name ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.bone)
                .lineLimit(1)
            Text("Lyrics")
                .font(.caption2)
                .foregroundColor(Theme.boneDim)
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.state {
        case .idle, .loading:
            Spacer()
            ProgressView().tint(Theme.bone)
            Spacer()
        case .plain(let text):
            plainView(text)
        case .synced(let lines, let offsetMs):
            syncedView(lines, offsetMs: offsetMs)
        case .unavailable(let reason):
            unavailableView(reason)
        }
    }

    // MARK: - Synced

    private func syncedView(_ lines: [LyricLine], offsetMs: Int) -> some View {
        let activeIdx = Self.activeIndex(lines: lines, fileMs: fileTimeMs, offsetMs: offsetMs)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(lines) { line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(line.id == activeIdx ? Theme.bone : Theme.boneFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .id(line.id)
                                .onTapGesture { seek(to: line, offsetMs: offsetMs) }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 44)
                }
                // A drag on the list pauses auto-scroll briefly so reading
                // ahead isn't yanked back to the active line every second.
                .simultaneousGesture(
                    DragGesture().onChanged { _ in userScrolledAt = Date() }
                )
                .onChange(of: audioPlayer.currentTime) { _ in
                    autoScroll(lines: lines, offsetMs: offsetMs, proxy: proxy)
                }
                .onAppear {
                    if let idx = activeIdx {
                        lastScrolledIndex = idx
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
            nudgeBar(offsetMs)
        }
    }

    private func autoScroll(lines: [LyricLine], offsetMs: Int, proxy: ScrollViewProxy) {
        guard let idx = Self.activeIndex(lines: lines, fileMs: fileTimeMs, offsetMs: offsetMs),
              idx != lastScrolledIndex else { return }
        lastScrolledIndex = idx
        if let t = userScrolledAt, Date().timeIntervalSince(t) < 4 { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(idx, anchor: .center)
        }
    }

    private func seek(to line: LyricLine, offsetMs: Int) {
        let cropStart = audioPlayer.currentTrack?.cropStartTime ?? 0
        let target = Double(line.timeMs + offsetMs) / 1000.0 - cropStart
        audioPlayer.seek(to: max(0, target))
    }

    /// Last line whose (timeMs + offset) has passed — binary search.
    static func activeIndex(lines: [LyricLine], fileMs: Int, offsetMs: Int) -> Int? {
        var lo = 0, hi = lines.count - 1
        var ans: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timeMs + offsetMs <= fileMs {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    private func nudgeBar(_ offsetMs: Int) -> some View {
        HStack(spacing: 16) {
            Text("Sync")
                .font(.caption)
                .foregroundColor(Theme.boneDim)
            Button { lyrics.nudgeOffset(by: -500) } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.bone)
            }
            Text(String(format: "%+.1fs", Double(offsetMs) / 1000))
                .font(.caption.monospacedDigit())
                .foregroundColor(offsetMs == 0 ? Theme.boneDim : Theme.red)
                .frame(width: 48)
            Button { lyrics.nudgeOffset(by: 500) } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.bone)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.smoke)
    }

    // MARK: - Plain / unavailable

    private func plainView(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(Theme.bone)
                .lineSpacing(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 44)
        }
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 40))
                .foregroundColor(Theme.boneFaint)
            Text(reason)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.boneDim)
            Button {
                loadCurrent(force: true)
            } label: {
                Text("Try Again")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.bone)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.smokeRaised))
            }
            Spacer()
        }
    }
}
