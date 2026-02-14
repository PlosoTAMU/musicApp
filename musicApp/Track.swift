import Foundation

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let url: URL
    let folderName: String
    var bookmarkData: Data?
    var cropStartTime: Double? // Time in seconds to start playback
    var cropEndTime: Double?   // Time in seconds to end playback
    
    // Custom init for runtime creation
    init(id: UUID = UUID(), name: String, url: URL, folderName: String, cropStartTime: Double? = nil, cropEndTime: Double? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.folderName = folderName
        self.cropStartTime = cropStartTime
        self.cropEndTime = cropEndTime
        
        // Create bookmark for imported files
        if folderName != "YouTube Downloads" {
            self.bookmarkData = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }
    
    // Explicit Codable conformance (required when you have custom init)
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case folderName
        case bookmarkData
        case cropStartTime
        case cropEndTime
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        folderName = try container.decode(String.self, forKey: .folderName)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        cropStartTime = try container.decodeIfPresent(Double.self, forKey: .cropStartTime)
        cropEndTime = try container.decodeIfPresent(Double.self, forKey: .cropEndTime)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)                    // ✅ FIXED: 'forKey'
        try container.encode(name, forKey: .name)                // ✅ FIXED: 'forKey'
        try container.encode(url, forKey: .url)                  // ✅ FIXED: 'forKey'
        try container.encode(folderName, forKey: .folderName)    // ✅ FIXED: 'forKey'
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)  // ✅ FIXED: 'forKey'
        try container.encodeIfPresent(cropStartTime, forKey: .cropStartTime)
        try container.encodeIfPresent(cropEndTime, forKey: .cropEndTime)
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
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return resolvedURL
            }
        }
        
        return url
    }
}