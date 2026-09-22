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

    init(image: UIImage) { media = .photo(image) }
    init(videoURL: URL) { media = .video(videoURL) }

    var image: UIImage? {
        if case .photo(let image) = media { return image }
        return nil
    }

    var videoURL: URL? {
        if case .video(let url) = media { return url }
        return nil
    }
}
