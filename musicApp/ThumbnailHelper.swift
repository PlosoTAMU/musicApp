import Foundation
import UIKit

extension Download {
    /// Full decode of this record's artwork — same resolver as every screen.
    func getThumbnailImage() -> UIImage? {
        guard let path = artworkPath else { return nil }
        return UIImage(contentsOfFile: path)
    }
}