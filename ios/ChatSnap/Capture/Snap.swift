import UIKit

/// A single captured moment, on its way to a group chat.
struct Snap: Identifiable {
    enum Media {
        case photo(UIImage)
        /// A local .mov, recorded or picked; uploaded as-is.
        case video(URL)
    }

    let id = UUID()
    let media: Media
    let takenAt = Date()
    /// Picked from the camera roll rather than shot here. Those keep their
    /// own shape, so they're shown whole (letterboxed), not filled.
    let isFromLibrary: Bool

    init(image: UIImage, fromLibrary: Bool = false) {
        media = .photo(image)
        isFromLibrary = fromLibrary
    }

    init(videoURL: URL, fromLibrary: Bool = false) {
        media = .video(videoURL)
        isFromLibrary = fromLibrary
    }

    var image: UIImage? {
        if case .photo(let image) = media { return image }
        return nil
    }

    var videoURL: URL? {
        if case .video(let url) = media { return url }
        return nil
    }
}
