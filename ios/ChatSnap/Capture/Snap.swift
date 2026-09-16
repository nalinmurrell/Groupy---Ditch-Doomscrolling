import UIKit

/// A single captured moment, on its way to a group chat.
struct Snap: Identifiable {
    let id = UUID()
    let image: UIImage
    let takenAt = Date()
}
