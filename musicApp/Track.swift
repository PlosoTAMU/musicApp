import Foundation

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let url: URL
    let folderName: String
    
    // Store bookmark data for security-scoped resources
    var bookmarkData: Data?
    
    init(id: UUID = UUID(), name: String, url: URL, folderName: String) {
        self.id = id
        self.name = name
        self.url = url
        self.folderName = folderName
        
        // Create bookmark for imported files
        if folderName != "YouTube Downloads" {
            self.bookmarkData = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
    
    // Equatable conformance
    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
    
    // Get the resolved URL (handles security-scoped resources)
    func resolvedURL() -> URL? {
        // YouTube downloads are in app's documents, no bookmark needed
        if folderName == "YouTube Downloads" {
            return url
        }
        
        // For imported files, resolve from bookmark
        if let bookmarkData = bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return resolvedURL
            }
        }
        
        return url
    }
}