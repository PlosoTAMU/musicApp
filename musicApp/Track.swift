// MARK: - Updated Track.swift
import Foundation

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let url: URL
    let folderName: String
    
    init(name: String, url: URL, folderName: String) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.folderName = folderName
    }
    
    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
}