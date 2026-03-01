import Foundation
import UIKit

extension Download {
    func getThumbnailImage() -> UIImage? {
        guard let path = resolvedThumbnailPath else { return nil }
        return UIImage(contentsOfFile: path)
    }
}