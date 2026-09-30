import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Snapchat's button left of the shutter: pick a photo or video from the
/// camera roll and it goes through the same review → Send To as a fresh snap.
struct CameraRollButton: View {
    let onPicked: (Snap) -> Void

    @State private var item: PhotosPickerItem?
    @State private var isLoading = false
    @State private var problem: String?

    /// Longer than this and a clip is usually past the upload limit anyway.
    private static let maxVideoSeconds: Double = 60

    var body: some View {
        PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .disabled(isLoading)
        .accessibilityLabel("Camera Roll")
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            item = nil
            Task { await load(picked) }
        }
        .alert("Can't use that video", isPresented: .init(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func load(_ picked: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }

        if picked.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try? await picked.loadTransferable(type: PickedMovie.self) else { return }
            let seconds = (try? await AVURLAsset(url: movie.url).load(.duration).seconds) ?? 0
            guard seconds <= Self.maxVideoSeconds else {
                try? FileManager.default.removeItem(at: movie.url)
                problem = "Videos can be up to \(Int(Self.maxVideoSeconds)) seconds long."
                return
            }
            onPicked(Snap(videoURL: movie.url, fromLibrary: true))
        } else {
            guard let data = try? await picked.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)?.downscaled(longestEdge: 2048) else { return }
            onPicked(Snap(image: image, fromLibrary: true))
        }
    }
}

/// A picked video, copied out of the Photos library into our temp folder
/// (the system's copy is deleted once the import returns).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

extension UIImage {
    /// At most `longestEdge` pixels on the long side, so a 48MP library
    /// photo doesn't become a 15MB upload.
    func downscaled(longestEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return self }
        let scale = longestEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
