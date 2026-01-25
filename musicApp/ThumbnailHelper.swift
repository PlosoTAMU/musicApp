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
        if let thumbPath = self.thumbnailPath,
           let image = UIImage(contentsOfFile: thumbPath) {
            return image
        }
        
        // Fallback to URL-based lookup
        return self.url.getThumbnailImage()
    }
}