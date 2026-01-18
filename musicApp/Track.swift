import Foundation

struct Track: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
}