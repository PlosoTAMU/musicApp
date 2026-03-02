// ⚠️  TEMPORARY FILE — DELETE AFTER ONE LAUNCH
//
// Drop this file into the project, build & run once on your device,
// then delete it. It runs a one-shot thumbnail purge on every cold launch
// until removed.
//
// What it does:
//   1. Reads every .jpg in Documents/Thumbnails/
//   2. Reads downloads.json to get the set of referenced thumbnail filenames
//   3. Deletes any .jpg that isn't referenced by any download
//   4. Prints a summary to the Xcode console

import Foundation

extension DownloadManager {

    /// Call once from app init. Scans Documents/Thumbnails and removes any
    /// .jpg file that is not referenced by a known, non-deleted Download.
    func oneTimeThumbnailPurge() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbnailsDir = docs.appendingPathComponent("Thumbnails")

        guard fm.fileExists(atPath: thumbnailsDir.path) else {
            print("🧹 [ThumbnailPurge] Thumbnails directory doesn't exist — nothing to do.")
            return
        }

        // All .jpg files currently on disk
        let allFiles: [URL]
        do {
            allFiles = try fm.contentsOfDirectory(at: thumbnailsDir,
                                                  includingPropertiesForKeys: [.fileSizeKey])
                             .filter { $0.pathExtension.lowercased() == "jpg" }
        } catch {
            print("❌ [ThumbnailPurge] Could not read Thumbnails dir: \(error)")
            return
        }

        // Set of thumbnail filenames that are referenced by a known download
        let referenced = Set(
            downloads
                .filter { !$0.pendingDeletion }
                .compactMap { $0.thumbnailPath }
                .map { ($0 as NSString).lastPathComponent }
        )

        let orphans = allFiles.filter { !referenced.contains($0.lastPathComponent) }

        print("🧹 [ThumbnailPurge] On-disk: \(allFiles.count)  Referenced: \(referenced.count)  Orphaned: \(orphans.count)")

        var deletedCount = 0
        var freedBytes: Int64 = 0

        for file in orphans {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? 0
            do {
                try fm.removeItem(at: file)
                freedBytes += size
                deletedCount += 1
                print("  🗑️  Deleted: \(file.lastPathComponent) (\(size / 1024) KB)")
            } catch {
                print("  ❌  Failed to delete \(file.lastPathComponent): \(error)")
            }
        }

        let mb = String(format: "%.2f", Double(freedBytes) / 1_048_576)
        print("✅ [ThumbnailPurge] Removed \(deletedCount) orphaned thumbnail(s), freed \(mb) MB.")
        print("⚠️  [ThumbnailPurge] Delete ThumbnailCleanup_DELETEME.swift from the project now.")
    }
}
