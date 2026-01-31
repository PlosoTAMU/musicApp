import Foundation
import UIKit

extension URL {
    func getThumbnailImage() -> UIImage? {
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let filename = self.lastPathComponent
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            return nil
        }
        return image
    }
}

extension Download {
    func getThumbnailImage() -> UIImage? {
        guard let path = resolvedThumbnailPath else { return nil }
        return UIImage(contentsOfFile: path)
    }
}